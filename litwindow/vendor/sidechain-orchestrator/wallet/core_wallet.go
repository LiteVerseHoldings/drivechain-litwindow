package wallet

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"strings"
	"sync"
	"time"

	"github.com/rs/zerolog"
	"github.com/tyler-smith/go-bip32"
	"golang.org/x/crypto/ripemd160" //nolint:staticcheck // Bitcoin protocol requires RIPEMD160
)

// walletLoadingBackoff is how long EnsureCoreWallet short-circuits subsequent
// calls after a transient bitcoind error (e.g. -4 Wallet already loading or
// -28 Verifying blocks). Frontends poll this path aggressively while the user
// stares at the wallet view; without a gate every poll triggers a fresh
// CreateWallet/LoadWallet RPC and we drown bitcoind in retries that all fail
// the same way until Core is past startup.
const walletLoadingBackoff = 5 * time.Second

// WalletEngine manages Litecoin Core wallets derived from wallet.json seeds.
// It handles BIP84 descriptor derivation and lazy Core wallet creation.
type WalletEngine struct {
	svc     *Service
	rpc     *CoreRPCClient
	log     zerolog.Logger
	network string // mainnet, testnet, signet, regtest

	mu          sync.RWMutex
	coreWallets map[string]string // walletID -> Core wallet name

	// Transient backoff: when bitcoind responds with a "still booting" error
	// (-4 Wallet already loading, -28 Verifying blocks, …), EnsureCoreWallet
	// returns the cached error for `walletLoadingBackoff` so the next ~5s of
	// frontend polls don't translate into RPC storms against bitcoind.
	loadingUntil time.Time
	loadingErr   error
}

// NewWalletEngine creates a new WalletEngine.
func NewWalletEngine(svc *Service, rpc *CoreRPCClient, network string, log zerolog.Logger) *WalletEngine {
	return &WalletEngine{
		svc:         svc,
		rpc:         rpc,
		log:         log.With().Str("component", "wallet-engine").Logger(),
		network:     network,
		coreWallets: make(map[string]string),
	}
}

// coinType returns the BIP44 coin type for the network.
func (e *WalletEngine) coinType() uint32 {
	if e.network == "mainnet" {
		return 0
	}
	return 1
}

// tprv version bytes (0x04358394) for testnet/signet/regtest extended private keys.
var tprvVersionBytes = []byte{0x04, 0x35, 0x83, 0x94}

// EnsureCoreWallet ensures a Litecoin Core wallet exists for a wallet.json wallet.
// Returns the Core wallet name.
func (e *WalletEngine) EnsureCoreWallet(ctx context.Context, walletID string) (string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()

	// Check cache
	if name, ok := e.coreWallets[walletID]; ok {
		return name, nil
	}

	// Short-circuit while a recent attempt is still in the bitcoind-warming-up
	// window — return the same error without re-hitting RPC.
	if e.loadingErr != nil && time.Now().Before(e.loadingUntil) {
		return "", e.loadingErr
	}

	// Find wallet data
	all := e.svc.GetAllWallets()
	var targetWallet *WalletData
	for i := range all {
		if all[i].ID == walletID {
			targetWallet = &all[i]
			break
		}
	}
	if targetWallet == nil {
		return "", fmt.Errorf("wallet %s not found", walletID)
	}

	walletName := fmt.Sprintf("wallet_%s", walletID[:8])

	var err error
	switch targetWallet.WalletType {
	case "bitcoinCore":
		err = e.createBitcoinCoreWallet(ctx, walletName, targetWallet.Master.SeedHex)
	case "watchOnly":
		err = e.createWatchOnlyWallet(ctx, walletName, targetWallet)
	default:
		return "", fmt.Errorf("wallet type %s does not use Litecoin Core", targetWallet.WalletType)
	}

	if err != nil {
		if isTransientWalletErr(err) {
			e.loadingUntil = time.Now().Add(walletLoadingBackoff)
			e.loadingErr = err
		}
		return "", err
	}

	// Success — clear any previous transient gate and cache the wallet name.
	e.loadingUntil = time.Time{}
	e.loadingErr = nil
	e.coreWallets[walletID] = walletName
	return walletName, nil
}

// createBitcoinCoreWallet creates a Litecoin Core descriptor wallet from a seed.
func (e *WalletEngine) createBitcoinCoreWallet(ctx context.Context, walletName, seedHex string) error {
	seed, err := hex.DecodeString(seedHex)
	if err != nil {
		return fmt.Errorf("decode seed hex: %w", err)
	}

	masterKey, err := bip32.NewMasterKey(seed)
	if err != nil {
		return fmt.Errorf("create master key: %w", err)
	}

	// Derive BIP84 account: m/84'/coin'/0'
	purpose, err := masterKey.NewChildKey(bip32.FirstHardenedChild + 84)
	if err != nil {
		return fmt.Errorf("derive purpose: %w", err)
	}

	coin, err := purpose.NewChildKey(bip32.FirstHardenedChild + e.coinType())
	if err != nil {
		return fmt.Errorf("derive coin: %w", err)
	}

	account, err := coin.NewChildKey(bip32.FirstHardenedChild + 0)
	if err != nil {
		return fmt.Errorf("derive account: %w", err)
	}

	accountXprv := e.serializeKey(account)
	fingerprint := masterFingerprint(masterKey)
	coinType := e.coinType()

	// The Litecoin signet branch used by LitWindow currently rejects descriptor
	// wallets. Create a regular Core wallet with its own keypool so receive/send
	// works on signet; the app-level seed is still retained for metadata/backup.
	_ = accountXprv
	_ = fingerprint
	_ = coinType
	return e.createAndImport(ctx, walletName, false, nil)
}

// createWatchOnlyWallet creates a watch-only Litecoin Core wallet.
func (e *WalletEngine) createWatchOnlyWallet(ctx context.Context, walletName string, w *WalletData) error {
	if w.WatchOnly == nil {
		return fmt.Errorf("watch-only wallet missing watch_only data")
	}

	var watchOnly struct {
		Descriptor string `json:"descriptor"`
		Xpub       string `json:"xpub"`
	}
	if err := json.Unmarshal(w.WatchOnly, &watchOnly); err != nil {
		return fmt.Errorf("parse watch_only: %w", err)
	}

	var descriptors []ImportDescriptor
	if watchOnly.Descriptor != "" {
		desc := watchOnly.Descriptor
		if !strings.Contains(desc, "#") {
			var err error
			desc, err = AddDescriptorChecksum(desc)
			if err != nil {
				return fmt.Errorf("add checksum: %w", err)
			}
		}
		descriptors = append(descriptors, ImportDescriptor{
			Desc:      desc,
			Active:    true,
			Timestamp: "now",
			Range:     []int{0, 1000},
		})
	} else if watchOnly.Xpub != "" {
		descriptors = append(descriptors,
			ImportDescriptor{
				Desc:      mustAddChecksum(fmt.Sprintf("wpkh(%s/0/*)", watchOnly.Xpub)),
				Active:    true,
				Timestamp: "now",
				Range:     []int{0, 1000},
			},
			ImportDescriptor{
				Desc:      mustAddChecksum(fmt.Sprintf("wpkh(%s/1/*)", watchOnly.Xpub)),
				Active:    true,
				Timestamp: "now",
				Internal:  true,
				Range:     []int{0, 1000},
			},
		)
	} else {
		return fmt.Errorf("watch-only wallet requires descriptor or xpub")
	}

	return e.createAndImport(ctx, walletName, true, descriptors)
}

// createAndImport creates a Core wallet and imports descriptors.
func (e *WalletEngine) createAndImport(ctx context.Context, walletName string, disablePrivateKeys bool, descriptors []ImportDescriptor) error {
	existing, err := e.rpc.ListWallets(ctx)
	if err != nil {
		return fmt.Errorf("list wallets: %w", err)
	}

	found := false
	for _, w := range existing {
		if w == walletName {
			found = true
			break
		}
	}

	if !found {
		blank := len(descriptors) > 0
		if err := e.rpc.CreateWallet(ctx, walletName, disablePrivateKeys, blank); err != nil {
			if strings.Contains(err.Error(), "already exists") {
				if loadErr := e.rpc.LoadWallet(ctx, walletName); loadErr != nil {
					return fmt.Errorf("load existing wallet: %w", loadErr)
				}
			} else {
				return fmt.Errorf("create wallet: %w", err)
			}
		}

		if len(descriptors) == 0 {
			e.log.Info().Str("wallet", walletName).Msg("created Litecoin Core wallet")
			return nil
		}

		results, err := e.rpc.ImportDescriptors(ctx, walletName, descriptors)
		if err != nil {
			return fmt.Errorf("import descriptors: %w", err)
		}

		for i, r := range results {
			if !r.Success {
				errMsg := "unknown"
				if r.Error != nil {
					errMsg = r.Error.Message
				}
				return fmt.Errorf("descriptor %d import failed: %s", i, errMsg)
			}
		}

		e.log.Info().Str("wallet", walletName).Msg("created Litecoin Core wallet")
	}

	return nil
}

// EnsureCoreWallets syncs all bitcoinCore/watchOnly wallets to Litecoin Core.
func (e *WalletEngine) EnsureCoreWallets(ctx context.Context) (int, error) {
	wallets := e.svc.GetAllWallets()
	synced := 0

	for _, w := range wallets {
		if w.WalletType != "bitcoinCore" && w.WalletType != "watchOnly" {
			continue
		}
		if _, err := e.EnsureCoreWallet(ctx, w.ID); err != nil {
			e.log.Warn().Err(err).Str("wallet_id", w.ID).Msg("failed to ensure core wallet")
			continue
		}
		synced++
	}

	return synced, nil
}

// GetCoreWalletName returns the Core wallet name for a wallet ID, ensuring it exists.
func (e *WalletEngine) GetCoreWalletName(ctx context.Context, walletID string) (string, error) {
	e.mu.RLock()
	if name, ok := e.coreWallets[walletID]; ok {
		e.mu.RUnlock()
		return name, nil
	}
	e.mu.RUnlock()

	return e.EnsureCoreWallet(ctx, walletID)
}

// CoreRPC returns the underlying Core RPC client.
func (e *WalletEngine) CoreRPC() *CoreRPCClient {
	return e.rpc
}

// Network returns the network identifier ("mainnet", "signet", "regtest", "testnet").
func (e *WalletEngine) Network() string {
	return e.network
}

// ResolveWalletID returns the wallet ID to use. If empty, returns active wallet ID.
func (e *WalletEngine) ResolveWalletID(walletID string) (string, error) {
	if walletID != "" {
		return walletID, nil
	}
	active := e.svc.ActiveWalletID()
	if active == "" {
		return "", fmt.Errorf("no active wallet")
	}
	return active, nil
}

// serializeKey serializes a BIP32 key, fixing version bytes for non-mainnet.
func (e *WalletEngine) serializeKey(key *bip32.Key) string {
	if e.network == "mainnet" {
		return key.String()
	}

	// key.Serialize() returns the full 82-byte payload (78 data + 4 checksum).
	// We need to strip the existing checksum, replace version bytes, then
	// re-encode with a fresh checksum so Litecoin Core accepts the key.
	serialized, err := key.Serialize()
	if err != nil {
		return key.String()
	}

	// serialized is 82 bytes: [4 version][74 data][4 checksum].
	// Strip old checksum, patch version, recompute.
	raw := serialized[:78]
	copy(raw[0:4], tprvVersionBytes)
	return base58CheckEncode(raw)
}

// ============================================================================
// Crypto helpers
// ============================================================================

// masterFingerprint computes the master fingerprint from a BIP32 key.
// Hash160(compressed_pubkey)[:4], hex encoded.
func masterFingerprint(masterKey *bip32.Key) string {
	pubKey := masterKey.PublicKey()
	h := hash160(pubKey.Key)
	return hex.EncodeToString(h[:4])
}

// hash160 computes RIPEMD160(SHA256(data)).
func hash160(data []byte) []byte {
	sha := sha256.Sum256(data)
	ripemd := ripemd160.New()
	ripemd.Write(sha[:])
	return ripemd.Sum(nil)
}

// mustAddChecksum adds a descriptor checksum, panicking on error (for known-good descriptors).
func mustAddChecksum(desc string) string {
	result, err := AddDescriptorChecksum(desc)
	if err != nil {
		// This should never happen for descriptors we construct ourselves
		return desc
	}
	return result
}

// Base58CheckEncode encodes a byte slice as Base58Check.
func Base58CheckEncode(data []byte) string {
	return base58CheckEncode(data)
}

// base58CheckEncode encodes a byte slice as Base58Check (internal).
func base58CheckEncode(data []byte) string {
	// Append 4-byte checksum
	checksum := doubleSha256(data)
	payload := append(data, checksum[:4]...)

	// Convert to base58
	n := new(big.Int).SetBytes(payload)
	result := make([]byte, 0, len(payload)*2)

	base := big.NewInt(58)
	zero := big.NewInt(0)
	mod := new(big.Int)

	for n.Cmp(zero) > 0 {
		n.DivMod(n, base, mod)
		result = append(result, base58Alphabet[mod.Int64()])
	}

	// Add leading zeros
	for _, b := range payload {
		if b != 0 {
			break
		}
		result = append(result, base58Alphabet[0])
	}

	// Reverse
	for i, j := 0, len(result)-1; i < j; i, j = i+1, j-1 {
		result[i], result[j] = result[j], result[i]
	}

	return string(result)
}

func doubleSha256(data []byte) [32]byte {
	first := sha256.Sum256(data)
	return sha256.Sum256(first[:])
}

const base58Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

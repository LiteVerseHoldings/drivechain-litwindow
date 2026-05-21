package wallet

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/btcsuite/btcd/btcutil"
	"github.com/stretchr/testify/require"
	"github.com/tyler-smith/go-bip32"
)

func TestDeriveCoreHDSeedWIFIsDeterministicAndLitecoinScoped(t *testing.T) {
	seed := MnemonicToSeed("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", "")
	master, err := bip32.NewMasterKey(seed)
	require.NoError(t, err)

	purpose, err := master.NewChildKey(bip32.FirstHardenedChild + 84)
	require.NoError(t, err)
	coin, err := purpose.NewChildKey(bip32.FirstHardenedChild + 1)
	require.NoError(t, err)
	account, err := coin.NewChildKey(bip32.FirstHardenedChild)
	require.NoError(t, err)

	engine := &WalletEngine{network: "signet"}
	wif1, err := engine.deriveCoreHDSeedWIF(account)
	require.NoError(t, err)
	wif2, err := engine.deriveCoreHDSeedWIF(account)
	require.NoError(t, err)

	require.Equal(t, wif1, wif2)
	decoded, err := btcutil.DecodeWIF(wif1)
	require.NoError(t, err)
	require.True(t, decoded.IsForNet(litecoinParams("signet")))
}

func TestSetHDSeedUsesWalletScopedRPC(t *testing.T) {
	var gotPath string
	var gotMethod string
	var gotParams []json.RawMessage

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		var req struct {
			Method string            `json:"method"`
			Params []json.RawMessage `json:"params"`
		}
		require.NoError(t, json.NewDecoder(r.Body).Decode(&req))
		gotMethod = req.Method
		gotParams = req.Params
		_, _ = w.Write([]byte(`{"result":null,"error":null}`))
	}))
	defer srv.Close()

	client := &CoreRPCClient{baseURL: srv.URL, client: srv.Client()}
	err := client.SetHDSeed(context.Background(), "wallet_abc123", true, "cSeedWIF")
	require.NoError(t, err)

	require.Equal(t, "/wallet/wallet_abc123", gotPath)
	require.Equal(t, "sethdseed", gotMethod)
	require.Len(t, gotParams, 2)
	require.JSONEq(t, "true", string(gotParams[0]))
	require.JSONEq(t, `"cSeedWIF"`, string(gotParams[1]))
}

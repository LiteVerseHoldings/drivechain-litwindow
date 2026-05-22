package litecoin

import (
	"errors"

	"github.com/btcsuite/btcd/btcutil"
	"github.com/btcsuite/btcd/chaincfg"
	"github.com/btcsuite/btcd/wire"
)

var (
	MainNetParams = litecoinParams("litecoin-mainnet", chaincfg.MainNetParams, 0xdbb6c0fb, "ltc", 0x30, 0x32, 0xb0)
	TestNetParams = litecoinParams("litecoin-testnet", chaincfg.TestNet3Params, 0xf1c8d2fd, "tltc", 0x6f, 0x3a, 0xef)
	SigNetParams  = litecoinParams("litecoin-signet", chaincfg.SigNetParams, 0xf1c8d2fc, "tltc", 0x6f, 0x3a, 0xef)
	RegTestParams = litecoinParams("litecoin-regtest", chaincfg.RegressionNetParams, 0xdab5bffa, "rltc", 0x6f, 0x3a, 0xef)
)

func init() {
	for _, params := range []*chaincfg.Params{&MainNetParams, &TestNetParams, &SigNetParams, &RegTestParams} {
		if err := chaincfg.Register(params); err != nil && !errors.Is(err, chaincfg.ErrDuplicateNet) {
			panic(err)
		}
	}
}

func litecoinParams(name string, base chaincfg.Params, net uint32, bech32HRP string, p2pkh byte, p2sh byte, wif byte) chaincfg.Params {
	params := base
	params.Name = name
	params.Net = wire.BitcoinNet(net)
	params.Bech32HRPSegwit = bech32HRP
	params.PubKeyHashAddrID = p2pkh
	params.ScriptHashAddrID = p2sh
	params.PrivateKeyID = wif
	params.WitnessPubKeyHashAddrID = 0
	params.WitnessScriptHashAddrID = 0
	params.HDCoinType = CoinType(&params)
	return params
}

func CoinType(params *chaincfg.Params) uint32 {
	if params != nil && params.Bech32HRPSegwit == "ltc" {
		return 2
	}
	return 1
}

func NormalizeAddress(address string, params *chaincfg.Params) (string, error) {
	if params == nil {
		return address, nil
	}

	if addr, err := btcutil.DecodeAddress(address, params); err == nil && addr.IsForNet(params) {
		return addr.EncodeAddress(), nil
	}

	for _, fallback := range []*chaincfg.Params{
		&SigNetParams,
		&TestNetParams,
		&RegTestParams,
		&MainNetParams,
		&chaincfg.SigNetParams,
		&chaincfg.TestNet3Params,
		&chaincfg.RegressionNetParams,
		&chaincfg.MainNetParams,
	} {
		addr, err := btcutil.DecodeAddress(address, fallback)
		if err != nil {
			continue
		}
		return ReencodeAddress(addr, params)
	}

	return address, nil
}

func ReencodeAddress(addr btcutil.Address, params *chaincfg.Params) (string, error) {
	switch a := addr.(type) {
	case *btcutil.AddressWitnessPubKeyHash:
		converted, err := btcutil.NewAddressWitnessPubKeyHash(a.ScriptAddress(), params)
		if err != nil {
			return "", err
		}
		return converted.EncodeAddress(), nil
	case *btcutil.AddressWitnessScriptHash:
		converted, err := btcutil.NewAddressWitnessScriptHash(a.ScriptAddress(), params)
		if err != nil {
			return "", err
		}
		return converted.EncodeAddress(), nil
	case *btcutil.AddressTaproot:
		converted, err := btcutil.NewAddressTaproot(a.ScriptAddress(), params)
		if err != nil {
			return "", err
		}
		return converted.EncodeAddress(), nil
	case *btcutil.AddressPubKeyHash:
		converted, err := btcutil.NewAddressPubKeyHash(a.ScriptAddress(), params)
		if err != nil {
			return "", err
		}
		return converted.EncodeAddress(), nil
	case *btcutil.AddressScriptHash:
		converted, err := btcutil.NewAddressScriptHashFromHash(a.ScriptAddress(), params)
		if err != nil {
			return "", err
		}
		return converted.EncodeAddress(), nil
	default:
		return addr.EncodeAddress(), nil
	}
}

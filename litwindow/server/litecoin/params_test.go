package litecoin

import (
	"testing"

	"github.com/btcsuite/btcd/btcutil"
)

func TestNormalizeAddressConvertsBitcoinSignetToLitecoinSignet(t *testing.T) {
	got, err := NormalizeAddress("tb1qd7spv5q28348xl4myc8zmh983w5jx32cjhkn97", &SigNetParams)
	if err != nil {
		t.Fatal(err)
	}

	const want = "tltc1qd7spv5q28348xl4myc8zmh983w5jx32ctl5d4h"
	if got != want {
		t.Fatalf("normalized address = %q, want %q", got, want)
	}

	addr, err := btcutil.DecodeAddress(got, &SigNetParams)
	if err != nil {
		t.Fatal(err)
	}
	if !addr.IsForNet(&SigNetParams) {
		t.Fatalf("address %q is not for Litecoin signet params", got)
	}
}

func TestMainnetParamsUseLitecoinBech32AndCoinType(t *testing.T) {
	addr, err := btcutil.NewAddressWitnessPubKeyHash(make([]byte, 20), &MainNetParams)
	if err != nil {
		t.Fatal(err)
	}
	if got := addr.EncodeAddress(); got[:4] != "ltc1" {
		t.Fatalf("mainnet address = %q, want ltc1 prefix", got)
	}
	if got := CoinType(&MainNetParams); got != 2 {
		t.Fatalf("mainnet coin type = %d, want 2", got)
	}
}

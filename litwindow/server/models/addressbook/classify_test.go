package addressbook

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"testing"

	pb "github.com/LayerTwo-Labs/sidesail/bitwindow/server/gen/bitwindowd/v1"
)

func depositChecksum(slot int, addr string) string {
	input := fmt.Sprintf("s%d_%s_", slot, addr)
	h := sha256.Sum256([]byte(input))
	return hex.EncodeToString(h[:3])
}

func TestClassifyAddress(t *testing.T) {
	// L1 addresses known to decode against their respective network params.
	const mainnetP2PKH = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
	const signetBech32 = "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"
	const regtestBech32 = "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
	const pmStyleString = "PM8TJTLJbPRGxSbc8EJi42Wrr6QbNSaSSVJ5Y3E4pbCYiTHUskHg13935Ubb7q8tx9GVbh2UuRnBc3WSyJHhUrw8KhprKnn9eDznYGieTzFcwQRya4GA"

	goodChecksum := depositChecksum(0, mainnetP2PKH)
	validDeposit := fmt.Sprintf("s0_%s_%s", mainnetP2PKH, goodChecksum)
	badChecksumDeposit := fmt.Sprintf("s0_%s_deadbe", mainnetP2PKH)
	depositWithJunkAddr := fmt.Sprintf("s0_notAnAddress_%s", depositChecksum(0, "notAnAddress"))
	slotOnly := fmt.Sprintf("s9_%s", mainnetP2PKH)

	cases := []struct {
		name  string
		input string
		want  pb.AddressType
	}{
		{"empty", "", pb.AddressType_ADDRESS_TYPE_UNSPECIFIED},
		{"whitespace only", "   ", pb.AddressType_ADDRESS_TYPE_UNSPECIFIED},
		{"garbage", "not-an-address", pb.AddressType_ADDRESS_TYPE_UNKNOWN},
		{"long PM-style string is not an address", pmStyleString, pb.AddressType_ADDRESS_TYPE_UNKNOWN},

		{"mainnet p2pkh", mainnetP2PKH, pb.AddressType_ADDRESS_TYPE_BITCOIN_L1},
		{"signet bech32", signetBech32, pb.AddressType_ADDRESS_TYPE_BITCOIN_L1},
		{"regtest bech32", regtestBech32, pb.AddressType_ADDRESS_TYPE_BITCOIN_L1},

		// Trim behaviour: trailing newline from paste.
		{"trimmed whitespace around l1", "  " + mainnetP2PKH + "\n", pb.AddressType_ADDRESS_TYPE_BITCOIN_L1},

		{"valid 3-part deposit", validDeposit, pb.AddressType_ADDRESS_TYPE_DRIVECHAIN_DEPOSIT},
		{"deposit with bad checksum", badChecksumDeposit, pb.AddressType_ADDRESS_TYPE_UNKNOWN},
		{"deposit with non-address body", depositWithJunkAddr, pb.AddressType_ADDRESS_TYPE_UNKNOWN},
		{"slot-only no checksum", slotOnly, pb.AddressType_ADDRESS_TYPE_UNKNOWN},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ClassifyAddress(tc.input)
			if got != tc.want {
				t.Fatalf("ClassifyAddress(%q) = %v, want %v", tc.input, got, tc.want)
			}
		})
	}
}

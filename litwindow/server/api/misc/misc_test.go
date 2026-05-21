package api_misc_test

import (
	"context"
	"testing"

	"connectrpc.com/connect"
	"github.com/LayerTwo-Labs/sidesail/bitwindow/server/database"
	miscv1 "github.com/LayerTwo-Labs/sidesail/bitwindow/server/gen/misc/v1"
	miscv1connect "github.com/LayerTwo-Labs/sidesail/bitwindow/server/gen/misc/v1/miscv1connect"
	"github.com/LayerTwo-Labs/sidesail/bitwindow/server/models/opreturns"
	"github.com/LayerTwo-Labs/sidesail/bitwindow/server/tests/apitests"
	"github.com/LayerTwo-Labs/sidesail/bitwindow/server/tests/mocks"
	commonv1 "github.com/LayerTwo-Labs/sidesail/sidechain-orchestrator/gen/cusf/common/v1"
	pb "github.com/LayerTwo-Labs/sidesail/sidechain-orchestrator/gen/cusf/mainchain/v1"
	corepb "github.com/barebitcoin/btc-buf/gen/bitcoin/bitcoind/v1alpha"
	"github.com/samber/lo"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

func TestService_ListOPReturn(t *testing.T) {
	t.Parallel()

	t.Run("list empty op returns", func(t *testing.T) {
		t.Parallel()

		database := database.Test(t)
		cli := miscv1connect.NewMiscServiceClient(apitests.API(t, database))

		resp, err := cli.ListOPReturn(context.Background(), connect.NewRequest(&emptypb.Empty{}))
		require.NoError(t, err)
		assert.Empty(t, resp.Msg.OpReturns)
	})

	t.Run("list op returns with data", func(t *testing.T) {
		t.Parallel()

		database := database.Test(t)
		// Insert test data using the Persist function
		ctx := context.Background()
		height := uint32(100)
		err := opreturns.Persist(ctx, database, []opreturns.OPReturn{
			{
				Height: &height,
				TxID:   "txid1",
				Vout:   0,
				Data:   []byte("test message"),
			},
		})
		require.NoError(t, err)

		cli := miscv1connect.NewMiscServiceClient(apitests.API(t, database))

		resp, err := cli.ListOPReturn(context.Background(), connect.NewRequest(&emptypb.Empty{}))
		require.NoError(t, err)
		require.Len(t, resp.Msg.OpReturns, 1)
		assert.Equal(t, "test message", resp.Msg.OpReturns[0].Message)
		assert.Equal(t, "txid1", resp.Msg.OpReturns[0].Txid)
		assert.EqualValues(t, 0, resp.Msg.OpReturns[0].Vout)
		assert.EqualValues(t, 100, lo.FromPtr(resp.Msg.OpReturns[0].Height))
	})
}

func TestService_TimestampFile(t *testing.T) {
	t.Parallel()

	t.Run("timestamp file success", func(t *testing.T) {
		t.Parallel()

		ctrl := gomock.NewController(t)
		mockWallet := mocks.NewMockWalletServiceClient(ctrl)

		mockWallet.EXPECT().
			SendTransaction(gomock.Any(), gomock.Any()).
			Return(&connect.Response[pb.SendTransactionResponse]{
				Msg: &pb.SendTransactionResponse{
					Txid: &commonv1.ReverseHex{
						Hex: &wrapperspb.StringValue{Value: "timestamp-txid"},
					},
				},
			}, nil)

		database := database.Test(t)
		cli := miscv1connect.NewMiscServiceClient(apitests.API(t, database, apitests.WithWallet(mockWallet)))

		resp, err := cli.TimestampFile(context.Background(), connect.NewRequest(&miscv1.TimestampFileRequest{
			Filename: "test-document.pdf",
			FileData: []byte("This is the content of the test document"),
		}))
		require.NoError(t, err)
		assert.NotEmpty(t, resp.Msg.Id)
		assert.NotEmpty(t, resp.Msg.FileHash)
		assert.NotEmpty(t, resp.Msg.Txid)
	})

	t.Run("timestamp file with empty filename", func(t *testing.T) {
		t.Parallel()

		database := database.Test(t)
		cli := miscv1connect.NewMiscServiceClient(apitests.API(t, database))

		_, err := cli.TimestampFile(context.Background(), connect.NewRequest(&miscv1.TimestampFileRequest{
			Filename: "",
			FileData: []byte("content"),
		}))
		require.Error(t, err)
		assert.Contains(t, err.Error(), "filename must be set")
	})

	t.Run("timestamp file with empty file data", func(t *testing.T) {
		t.Parallel()

		database := database.Test(t)
		cli := miscv1connect.NewMiscServiceClient(apitests.API(t, database))

		_, err := cli.TimestampFile(context.Background(), connect.NewRequest(&miscv1.TimestampFileRequest{
			Filename: "test.pdf",
			FileData: []byte{},
		}))
		require.Error(t, err)
		assert.Contains(t, err.Error(), "file data must be set")
	})

	t.Run("timestamp same file twice returns same timestamp", func(t *testing.T) {
		t.Parallel()

		ctrl := gomock.NewController(t)
		mockWallet := mocks.NewMockWalletServiceClient(ctrl)

		// Only one transaction should be sent
		mockWallet.EXPECT().
			SendTransaction(gomock.Any(), gomock.Any()).
			Return(&connect.Response[pb.SendTransactionResponse]{
				Msg: &pb.SendTransactionResponse{
					Txid: &commonv1.ReverseHex{
						Hex: &wrapperspb.StringValue{Value: "timestamp-txid"},
					},
				},
			}, nil).
			Times(1)

		database := database.Test(t)
		cli := miscv1connect.NewMiscServiceClient(apitests.API(t, database, apitests.WithWallet(mockWallet)))

		fileData := []byte("duplicate content")

		// First timestamp
		resp1, err := cli.TimestampFile(context.Background(), connect.NewRequest(&miscv1.TimestampFileRequest{
			Filename: "first.pdf",
			FileData: fileData,
		}))
		require.NoError(t, err)

		// Second timestamp with same content
		resp2, err := cli.TimestampFile(context.Background(), connect.NewRequest(&miscv1.TimestampFileRequest{
			Filename: "second.pdf",
			FileData: fileData,
		}))
		require.NoError(t, err)

		// Should return the same timestamp ID and hash
		assert.Equal(t, resp1.Msg.Id, resp2.Msg.Id)
		assert.Equal(t, resp1.Msg.FileHash, resp2.Msg.FileHash)
	})
}

func TestService_ListTimestamps(t *testing.T) {
	t.Parallel()

	t.Run("list empty timestamps", func(t *testing.T) {
		t.Parallel()

		ctrl := gomock.NewController(t)
		mockBitcoind := mocks.NewMockBitcoinServiceClient(ctrl)

		// Background operations
		mockBitcoind.EXPECT().
			ListWallets(gomock.Any(), gomock.Any()).
			Return(&connect.Response[corepb.ListWalletsResponse]{
				Msg: &corepb.ListWalletsResponse{Wallets: []string{}},
			}, nil).
			AnyTimes()
		mockBitcoind.EXPECT().
			CreateWallet(gomock.Any(), gomock.Any()).
			Return(&connect.Response[corepb.CreateWalletResponse]{
				Msg: &corepb.CreateWalletResponse{Name: "cheque_watch"},
			}, nil).
			AnyTimes()
		// Required for ListTimestamps to get current block height
		mockBitcoind.EXPECT().
			GetBlockchainInfo(gomock.Any(), gomock.Any()).
			Return(&connect.Response[corepb.GetBlockchainInfoResponse]{
				Msg: &corepb.GetBlockchainInfoResponse{
					Chain:  "signet",
					Blocks: 1000,
				},
			}, nil).
			AnyTimes()

		database := database.Test(t)
		cli := miscv1connect.NewMiscServiceClient(apitests.API(t, database, apitests.WithBitcoind(mockBitcoind)))

		resp, err := cli.ListTimestamps(context.Background(), connect.NewRequest(&emptypb.Empty{}))
		require.NoError(t, err)
		assert.Empty(t, resp.Msg.Timestamps)
	})

	t.Run("list timestamps with data", func(t *testing.T) {
		t.Parallel()

		ctrl := gomock.NewController(t)
		mockWallet := mocks.NewMockWalletServiceClient(ctrl)
		mockBitcoind := mocks.NewMockBitcoinServiceClient(ctrl)

		mockWallet.EXPECT().
			SendTransaction(gomock.Any(), gomock.Any()).
			Return(&connect.Response[pb.SendTransactionResponse]{
				Msg: &pb.SendTransactionResponse{
					Txid: &commonv1.ReverseHex{
						Hex: &wrapperspb.StringValue{Value: "timestamp-txid-1"},
					},
				},
			}, nil).
			Times(2)

		// Background operations
		mockBitcoind.EXPECT().
			ListWallets(gomock.Any(), gomock.Any()).
			Return(&connect.Response[corepb.ListWalletsResponse]{
				Msg: &corepb.ListWalletsResponse{Wallets: []string{}},
			}, nil).
			AnyTimes()
		mockBitcoind.EXPECT().
			CreateWallet(gomock.Any(), gomock.Any()).
			Return(&connect.Response[corepb.CreateWalletResponse]{
				Msg: &corepb.CreateWalletResponse{Name: "cheque_watch"},
			}, nil).
			AnyTimes()
		// Required for ListTimestamps to get current block height
		mockBitcoind.EXPECT().
			GetBlockchainInfo(gomock.Any(), gomock.Any()).
			Return(&connect.Response[corepb.GetBlockchainInfoResponse]{
				Msg: &corepb.GetBlockchainInfoResponse{
					Chain:  "signet",
					Blocks: 1000,
				},
			}, nil).
			AnyTimes()

		database := database.Test(t)
		cli := miscv1connect.NewMiscServiceClient(apitests.API(t, database,
			apitests.WithWallet(mockWallet),
			apitests.WithBitcoind(mockBitcoind),
		))

		// Create some timestamps
		_, err := cli.TimestampFile(context.Background(), connect.NewRequest(&miscv1.TimestampFileRequest{
			Filename: "file1.pdf",
			FileData: []byte("content 1"),
		}))
		require.NoError(t, err)

		_, err = cli.TimestampFile(context.Background(), connect.NewRequest(&miscv1.TimestampFileRequest{
			Filename: "file2.pdf",
			FileData: []byte("content 2"),
		}))
		require.NoError(t, err)

		resp, err := cli.ListTimestamps(context.Background(), connect.NewRequest(&emptypb.Empty{}))
		require.NoError(t, err)
		require.Len(t, resp.Msg.Timestamps, 2)
	})
}

func TestService_VerifyTimestamp(t *testing.T) {
	t.Parallel()

	t.Run("verify non-existent timestamp", func(t *testing.T) {
		t.Parallel()

		database := database.Test(t)
		cli := miscv1connect.NewMiscServiceClient(apitests.API(t, database))

		_, err := cli.VerifyTimestamp(context.Background(), connect.NewRequest(&miscv1.VerifyTimestampRequest{
			FileData: []byte("unknown content"),
		}))
		require.Error(t, err)
	})

	t.Run("verify with empty file data", func(t *testing.T) {
		t.Parallel()

		database := database.Test(t)
		cli := miscv1connect.NewMiscServiceClient(apitests.API(t, database))

		_, err := cli.VerifyTimestamp(context.Background(), connect.NewRequest(&miscv1.VerifyTimestampRequest{
			FileData: []byte{},
		}))
		require.Error(t, err)
		assert.Contains(t, err.Error(), "file data must be set")
	})

	t.Run("verify existing timestamp", func(t *testing.T) {
		t.Parallel()

		ctrl := gomock.NewController(t)
		mockWallet := mocks.NewMockWalletServiceClient(ctrl)
		mockBitcoind := mocks.NewMockBitcoinServiceClient(ctrl)

		mockWallet.EXPECT().
			SendTransaction(gomock.Any(), gomock.Any()).
			Return(&connect.Response[pb.SendTransactionResponse]{
				Msg: &pb.SendTransactionResponse{
					Txid: &commonv1.ReverseHex{
						Hex: &wrapperspb.StringValue{Value: "timestamp-txid"},
					},
				},
			}, nil)

		// Background operations
		mockBitcoind.EXPECT().
			ListWallets(gomock.Any(), gomock.Any()).
			Return(&connect.Response[corepb.ListWalletsResponse]{
				Msg: &corepb.ListWalletsResponse{Wallets: []string{}},
			}, nil).
			AnyTimes()
		mockBitcoind.EXPECT().
			CreateWallet(gomock.Any(), gomock.Any()).
			Return(&connect.Response[corepb.CreateWalletResponse]{
				Msg: &corepb.CreateWalletResponse{Name: "cheque_watch"},
			}, nil).
			AnyTimes()
		// Required for VerifyTimestamp to get current block height
		mockBitcoind.EXPECT().
			GetBlockchainInfo(gomock.Any(), gomock.Any()).
			Return(&connect.Response[corepb.GetBlockchainInfoResponse]{
				Msg: &corepb.GetBlockchainInfoResponse{
					Chain:  "signet",
					Blocks: 1000,
				},
			}, nil).
			AnyTimes()

		database := database.Test(t)
		cli := miscv1connect.NewMiscServiceClient(apitests.API(t, database,
			apitests.WithWallet(mockWallet),
			apitests.WithBitcoind(mockBitcoind),
		))

		fileData := []byte("content to verify")

		// First create the timestamp
		_, err := cli.TimestampFile(context.Background(), connect.NewRequest(&miscv1.TimestampFileRequest{
			Filename: "verify-test.pdf",
			FileData: fileData,
		}))
		require.NoError(t, err)

		// Now verify it
		resp, err := cli.VerifyTimestamp(context.Background(), connect.NewRequest(&miscv1.VerifyTimestampRequest{
			FileData: fileData,
		}))
		require.NoError(t, err)
		assert.NotNil(t, resp.Msg.Timestamp)
		assert.Contains(t, resp.Msg.Message, "verified")
	})
}

package api_misc

import (
	"context"
	"database/sql"
	"fmt"

	"connectrpc.com/connect"
	"github.com/LayerTwo-Labs/sidesail/bitwindow/server/engines"
	miscv1 "github.com/LayerTwo-Labs/sidesail/bitwindow/server/gen/misc/v1"
	rpc "github.com/LayerTwo-Labs/sidesail/bitwindow/server/gen/misc/v1/miscv1connect"
	"github.com/LayerTwo-Labs/sidesail/bitwindow/server/models/opreturns"
	"github.com/LayerTwo-Labs/sidesail/bitwindow/server/models/timestamps"
	service "github.com/LayerTwo-Labs/sidesail/bitwindow/server/service"
	corepb "github.com/barebitcoin/btc-buf/gen/bitcoin/bitcoind/v1alpha"
	corerpc "github.com/barebitcoin/btc-buf/gen/bitcoin/bitcoind/v1alpha/bitcoindv1alphaconnect"
	"github.com/rs/zerolog"
	"github.com/samber/lo"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/timestamppb"
)

var _ rpc.MiscServiceHandler = new(Server)

// New creates a new misc Server. Misc is a horrible name, but can't think of
// anything else just yet.
func New(
	database *sql.DB,
	timestampEngine *engines.TimestampEngine,
	bitcoind *service.Service[corerpc.BitcoinServiceClient],
) *Server {
	return &Server{
		database:        database,
		timestampEngine: timestampEngine,
		bitcoind:        bitcoind,
	}
}

type Server struct {
	rpc.UnimplementedMiscServiceHandler

	database        *sql.DB
	timestampEngine *engines.TimestampEngine
	bitcoind        *service.Service[corerpc.BitcoinServiceClient]
}

// listOPReturnLimit is the cap for the gRPC ListOPReturn handler. The
// UI is the only consumer and only renders the most-recent N; without
// a cap each poll dragged every row in the table back through the wire.
const listOPReturnLimit = 1000

// ListOPReturn implements miscv1connect.MiscServiceHandler.
func (s *Server) ListOPReturn(ctx context.Context, req *connect.Request[emptypb.Empty]) (*connect.Response[miscv1.ListOPReturnResponse], error) {
	opReturns, err := opreturns.List(ctx, s.database, listOPReturnLimit)
	if err != nil {
		zerolog.Ctx(ctx).Error().Err(err).Msg("could not list op returns")
		return nil, err
	}

	return connect.NewResponse(&miscv1.ListOPReturnResponse{
		OpReturns: lo.Map(opReturns, opReturnToProto),
	}), nil
}

func opReturnToProto(opReturn opreturns.OPReturn, _ int) *miscv1.OPReturn {
	var height *int32
	if opReturn.Height != nil {
		height = lo.ToPtr(int32(*opReturn.Height))
	}
	return &miscv1.OPReturn{
		Id:         opReturn.ID,
		Message:    opreturns.OPReturnToReadable(opReturn.Data),
		Txid:       opReturn.TxID,
		Vout:       opReturn.Vout,
		Height:     height,
		CreateTime: timestamppb.New(lo.FromPtr(opReturn.CreatedAt)),
	}
}

// TimestampFile implements miscv1connect.MiscServiceHandler.
func (s *Server) TimestampFile(ctx context.Context, req *connect.Request[miscv1.TimestampFileRequest]) (*connect.Response[miscv1.TimestampFileResponse], error) {
	if req.Msg.Filename == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("filename must be set"))
	}
	if len(req.Msg.FileData) == 0 {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("file data must be set"))
	}

	ts, err := s.timestampEngine.TimestampFile(ctx, req.Msg.Filename, req.Msg.FileData)
	if err != nil {
		return nil, fmt.Errorf("timestamp file: %w", err)
	}

	txid := ""
	if ts.TxID != nil {
		txid = *ts.TxID
	}

	return connect.NewResponse(&miscv1.TimestampFileResponse{
		Id:       ts.ID,
		FileHash: ts.FileHash,
		Txid:     txid,
	}), nil
}

// ListTimestamps implements miscv1connect.MiscServiceHandler.
func (s *Server) ListTimestamps(ctx context.Context, req *connect.Request[emptypb.Empty]) (*connect.Response[miscv1.ListTimestampsResponse], error) {
	tsList, err := s.timestampEngine.ListTimestamps(ctx)
	if err != nil {
		return nil, fmt.Errorf("list timestamps: %w", err)
	}

	currentBlockHeight := s.getCurrentBlockHeight(ctx)

	return connect.NewResponse(&miscv1.ListTimestampsResponse{
		Timestamps: lo.Map(tsList, func(ts timestamps.FileTimestamp, _ int) *miscv1.FileTimestamp {
			return timestampToProto(ts, currentBlockHeight)
		}),
	}), nil
}

func timestampToProto(ts timestamps.FileTimestamp, currentBlockHeight int64) *miscv1.FileTimestamp {
	proto := &miscv1.FileTimestamp{
		Id:        ts.ID,
		Filename:  ts.Filename,
		FileHash:  ts.FileHash,
		Status:    string(ts.Status),
		CreatedAt: timestamppb.New(ts.CreatedAt),
	}

	if ts.TxID != nil {
		proto.Txid = ts.TxID
	}
	if ts.BlockHeight != nil {
		proto.BlockHeight = ts.BlockHeight
		if currentBlockHeight > 0 {
			proto.Confirmations = uint32(currentBlockHeight - *ts.BlockHeight + 1)
		}
	}
	if ts.ConfirmedAt != nil {
		proto.ConfirmedAt = timestamppb.New(*ts.ConfirmedAt)
	}

	return proto
}

// VerifyTimestamp implements miscv1connect.MiscServiceHandler.
func (s *Server) VerifyTimestamp(ctx context.Context, req *connect.Request[miscv1.VerifyTimestampRequest]) (*connect.Response[miscv1.VerifyTimestampResponse], error) {
	if len(req.Msg.FileData) == 0 {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("file data must be set"))
	}

	filename := ""
	if req.Msg.Filename != nil {
		filename = *req.Msg.Filename
	}

	ts, err := s.timestampEngine.VerifyTimestamp(ctx, req.Msg.FileData, filename)
	if err != nil {
		return nil, connect.NewError(connect.CodeNotFound, err)
	}

	currentBlockHeight := s.getCurrentBlockHeight(ctx)

	return connect.NewResponse(&miscv1.VerifyTimestampResponse{
		Timestamp: timestampToProto(*ts, currentBlockHeight),
		Message:   fmt.Sprintf("File verified! Transaction: %s", *ts.TxID),
	}), nil
}

func (s *Server) getCurrentBlockHeight(ctx context.Context) int64 {
	bitcoind, err := s.bitcoind.Get(ctx)
	if err != nil {
		return 0
	}
	info, err := bitcoind.GetBlockchainInfo(ctx, &connect.Request[corepb.GetBlockchainInfoRequest]{})
	if err != nil {
		return 0
	}
	return int64(info.Msg.Blocks)
}

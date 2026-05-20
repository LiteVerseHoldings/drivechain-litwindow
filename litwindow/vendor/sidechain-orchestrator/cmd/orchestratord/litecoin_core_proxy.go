package main

import (
	"context"
	"encoding/json"
	"fmt"

	"connectrpc.com/connect"
	corepb "github.com/barebitcoin/btc-buf/gen/bitcoin/bitcoind/v1alpha"
	"github.com/barebitcoin/btc-buf/rpcclient"
	coreproxy "github.com/barebitcoin/btc-buf/server"
)

type litecoinCompatibleCoreProxy struct {
	*coreproxy.Bitcoind

	raw *rpcclient.Client
}

type litecoinBlockchainInfo struct {
	BestBlockHash        string  `json:"bestblockhash"`
	Blocks               int64   `json:"blocks"`
	Headers              int64   `json:"headers"`
	Chain                string  `json:"chain"`
	ChainWork            string  `json:"chainwork"`
	InitialBlockDownload bool    `json:"initialblockdownload"`
	VerificationProgress float64 `json:"verificationprogress"`

	// Litecoin Core exposes modern softforks as an object, while older
	// btcjson decoders expect an array. Keep the field raw and ignore it.
	SoftForks json.RawMessage `json:"softforks"`
}

func newLitecoinCompatibleCoreProxy(
	ctx context.Context,
	host string,
	user string,
	pass string,
	proxy *coreproxy.Bitcoind,
) (*litecoinCompatibleCoreProxy, error) {
	raw, err := rpcclient.New(ctx, &rpcclient.ConnConfig{
		User:       user,
		Pass:       pass,
		DisableTLS: true,
		Host:       host,
	})
	if err != nil {
		return nil, fmt.Errorf("new compatibility RPC client: %w", err)
	}

	return &litecoinCompatibleCoreProxy{
		Bitcoind: proxy,
		raw:      raw,
	}, nil
}

func (p *litecoinCompatibleCoreProxy) GetBlockchainInfo(
	ctx context.Context,
	_ *connect.Request[corepb.GetBlockchainInfoRequest],
) (*connect.Response[corepb.GetBlockchainInfoResponse], error) {
	result, err := p.raw.RawRequest(ctx, "getblockchaininfo", nil)
	if err != nil {
		return nil, err
	}

	var info litecoinBlockchainInfo
	if err := json.Unmarshal(result, &info); err != nil {
		return nil, fmt.Errorf("unmarshal getblockchaininfo response: %w", err)
	}

	return connect.NewResponse(&corepb.GetBlockchainInfoResponse{
		BestBlockHash:        info.BestBlockHash,
		Blocks:               uint32(info.Blocks),
		Headers:              uint32(info.Headers),
		Chain:                info.Chain,
		ChainWork:            info.ChainWork,
		InitialBlockDownload: info.InitialBlockDownload,
		VerificationProgress: info.VerificationProgress,
	}), nil
}

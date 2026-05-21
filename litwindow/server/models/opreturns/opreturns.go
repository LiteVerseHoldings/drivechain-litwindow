package opreturns

import (
	"context"
	"database/sql"
	"encoding/hex"
	"fmt"
	"sync"
	"time"
	"unicode"

	sq "github.com/Masterminds/squirrel"
	"github.com/btcsuite/btcd/btcutil"
	"github.com/rs/zerolog"
)

// Backstop TTL for cached List entries. Persist invalidates; TTL only
// matters if a query races a write.
const listCacheTTL = 2 * time.Second

// Caches are keyed by *sql.DB so parallel tests with their own DBs
// don't share entries. Production has one *sql.DB per network so this
// is effectively a singleton.

type listCacheEntry struct {
	rows []OPReturn
	at   time.Time
}

var (
	listCacheMu      sync.RWMutex
	listCacheEntries = map[*sql.DB]map[int]listCacheEntry{}
)

// invalidateCaches drops cached List entries for db.
func invalidateCaches(db *sql.DB) {
	listCacheMu.Lock()
	delete(listCacheEntries, db)
	listCacheMu.Unlock()
}

func Persist(
	ctx context.Context, db *sql.DB, values []OPReturn,
) error {
	if len(values) == 0 {
		return nil
	}

	start := time.Now()
	builder := sq.
		Insert("op_returns").
		Columns("txid", "vout", "op_return_data", "fee_sats", "height", "created_at")

	for _, value := range values {
		createdAt := time.Now()
		if value.CreatedAt != nil {
			createdAt = *value.CreatedAt
		}
		builder = builder.Values(
			value.TxID, value.Vout,
			// Much easier to work with hex strings in the database! We're
			// storing this in a string column, should've been BLOB?
			hex.EncodeToString(value.Data),
			value.Fee, value.Height, createdAt,
		)
	}

	builder = builder.Suffix(
		`ON CONFLICT (txid, vout) DO UPDATE SET 
			op_return_data = excluded.op_return_data, 
			height = excluded.height, 
			fee_sats = excluded.fee_sats`,
	)

	sql, args := builder.MustSql()
	if _, err := db.ExecContext(ctx, sql, args...); err != nil {
		return fmt.Errorf("persist %d OP_RETURN(s): %w", len(values), err)
	}

	invalidateCaches(db)

	zerolog.Ctx(ctx).Debug().
		Msgf("opreturns: persisted %d OP_RETURN(s) in %s", len(values), time.Since(start))

	return nil
}

type OPReturn struct {
	ID        int64
	TxID      string
	Vout      int32
	Data      []byte
	Fee       btcutil.Amount // 0 can either mean zero fee or unknown fee
	Height    *uint32
	CreatedAt *time.Time
}

// List returns the most-recent OP_RETURNs, ordered by created_at desc,
// capped at `limit`. Pass 0 (or any value <= 0) to skip the cap — only
// do that when the caller genuinely needs the full table; this table
// grows linearly with chain height. The returned slice is freshly
// allocated; element values are shared, so OPReturn fields must be
// treated read-only.
func List(ctx context.Context, db *sql.DB, limit int) ([]OPReturn, error) {
	listCacheMu.RLock()
	cached, hit := listCacheEntries[db][limit]
	listCacheMu.RUnlock()
	if hit && time.Since(cached.at) < listCacheTTL {
		out := make([]OPReturn, len(cached.rows))
		copy(out, cached.rows)
		return out, nil
	}

	query := `
		SELECT id, txid, vout, unhex(op_return_data), fee_sats, height, created_at
		FROM op_returns
		ORDER BY created_at DESC
	`
	args := []any{}
	if limit > 0 {
		query += "\nLIMIT ?"
		args = append(args, limit)
	}

	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("list: query op_returns: %w", err)
	}
	defer rows.Close()

	var opReturns []OPReturn
	for rows.Next() {
		var opReturn OPReturn
		err := rows.Scan(
			&opReturn.ID, &opReturn.TxID, &opReturn.Vout,
			&opReturn.Data, &opReturn.Fee, &opReturn.Height, &opReturn.CreatedAt,
		)
		if err != nil {
			return nil, fmt.Errorf("list: scan op_return: %w", err)
		}
		opReturns = append(opReturns, opReturn)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list: iterate op_returns: %w", err)
	}

	snapshot := make([]OPReturn, len(opReturns))
	copy(snapshot, opReturns)
	listCacheMu.Lock()
	byLimit, ok := listCacheEntries[db]
	if !ok {
		byLimit = map[int]listCacheEntry{}
		listCacheEntries[db] = byLimit
	}
	byLimit[limit] = listCacheEntry{rows: snapshot, at: time.Now()}
	listCacheMu.Unlock()

	return opReturns, nil
}

func OPReturnToReadable(data []byte) string {
	// First try to decode as hex
	decoded, err := hex.DecodeString(string(data))
	if err == nil {
		// Check if decoded data is human readable
		isHumanReadable := true
		for _, r := range string(decoded) {
			if !unicode.IsPrint(r) || r > 127 {
				isHumanReadable = false
				break
			}
		}
		if isHumanReadable {
			return string(decoded)
		}
	}

	// If not hex or not human readable when decoded, try direct string
	str := string(data)
	isHumanReadable := true
	for _, r := range str {
		if !unicode.IsPrint(r) || r > 127 {
			isHumanReadable = false
			break
		}
	}
	if isHumanReadable {
		return str
	}

	// If all else fails, return as hex
	return hex.EncodeToString(data)
}

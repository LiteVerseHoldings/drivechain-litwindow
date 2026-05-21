package opreturns

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/LayerTwo-Labs/sidesail/bitwindow/server/database"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// List(..., limit) must cap rows at the requested limit.
func TestList_LimitCaps(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := database.Test(t)

	const total = 50
	const limit = 10
	rows := make([]OPReturn, 0, total)
	for i := 0; i < total; i++ {
		h := uint32(i + 1)
		now := time.Now().Add(time.Duration(i) * time.Millisecond)
		rows = append(rows, OPReturn{
			Height:    &h,
			TxID:      fmt.Sprintf("tx-%d", i),
			Vout:      0,
			Data:      []byte("payload"),
			CreatedAt: &now,
		})
	}
	require.NoError(t, Persist(ctx, db, rows))

	got, err := List(ctx, db, limit)
	require.NoError(t, err)
	assert.Len(t, got, limit)
}

// List(..., 0) is the explicit "full table" escape hatch (bitdrive).
func TestList_LimitZeroIsUnbounded(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := database.Test(t)

	const n = 50
	rows := make([]OPReturn, 0, n)
	for i := 0; i < n; i++ {
		h := uint32(i + 1)
		now := time.Now().Add(time.Duration(i) * time.Millisecond)
		rows = append(rows, OPReturn{
			Height:    &h,
			TxID:      fmt.Sprintf("tx-%d", i),
			Vout:      0,
			Data:      []byte("payload"),
			CreatedAt: &now,
		})
	}
	require.NoError(t, Persist(ctx, db, rows))

	got, err := List(ctx, db, 0)
	require.NoError(t, err)
	assert.Len(t, got, n)
}

// Closing the DB after the first call proves the second read is served
// purely from cache (a real query would fail).
func TestListCache_HitAfterMiss(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := database.Test(t)

	h := uint32(1)
	now := time.Now()
	require.NoError(t, Persist(ctx, db, []OPReturn{{
		Height: &h, TxID: "tx", Vout: 0, Data: []byte("hi"), CreatedAt: &now,
	}}))

	first, err := List(ctx, db, 100)
	require.NoError(t, err)
	require.Len(t, first, 1)

	require.NoError(t, db.Close())

	// If the cache wasn't honored, this would error with "sql: database is closed".
	second, err := List(ctx, db, 100)
	require.NoError(t, err, "second call must hit the cache, not the closed DB")
	assert.Equal(t, first, second)
}

// Persist must drop the cache so the next read sees the new row.
func TestListCache_InvalidatedByPersist(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := database.Test(t)

	first, err := List(ctx, db, 100)
	require.NoError(t, err)
	require.Empty(t, first, "fresh DB must list empty")

	h := uint32(1)
	now := time.Now()
	require.NoError(t, Persist(ctx, db, []OPReturn{{
		Height: &h, TxID: "tx", Vout: 0, Data: []byte("hi"), CreatedAt: &now,
	}}))

	second, err := List(ctx, db, 100)
	require.NoError(t, err)
	assert.Len(t, second, 1, "Persist must invalidate the cached empty result")
}

// Cache must not bleed entries across DBs.
func TestListCache_PerDBIsolation(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	dbA := database.Test(t)
	dbB := database.Test(t)

	h := uint32(1)
	now := time.Now()
	require.NoError(t, Persist(ctx, dbA, []OPReturn{{
		Height: &h, TxID: "in-a", Vout: 0, Data: []byte("a"), CreatedAt: &now,
	}}))

	gotA, err := List(ctx, dbA, 100)
	require.NoError(t, err)
	require.Len(t, gotA, 1)

	gotB, err := List(ctx, dbB, 100)
	require.NoError(t, err)
	assert.Empty(t, gotB, "dbB must not see dbA's rows via shared cache")
}

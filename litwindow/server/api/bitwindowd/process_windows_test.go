package api_bitwindowd

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestParseTasklistCSVLine(t *testing.T) {
	assert.Equal(t,
		[]string{"litecoind.exe", "22180", "Console", "1", "100,000 K"},
		parseTasklistCSVLine(`"litecoind.exe","22180","Console","1","100,000 K"`),
	)
	assert.Nil(t, parseTasklistCSVLine(`INFO: No tasks are running which match the specified criteria.`))
	assert.Nil(t, parseTasklistCSVLine(""))
}

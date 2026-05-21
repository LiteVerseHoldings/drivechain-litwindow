package bandwidth

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestWindowsNetstatPIDMatching(t *testing.T) {
	pid := "1234"
	lines := []string{
		"  TCP    127.0.0.1:9333    127.0.0.1:55000    ESTABLISHED     1234",
		"  TCP    127.0.0.1:1234    127.0.0.1:55001    ESTABLISHED     9999",
		"  TCP    127.0.0.1:9333    127.0.0.1:55002    ESTABLISHED     12345",
	}

	count := int32(0)
	for _, line := range lines {
		fields := strings.Fields(line)
		if len(fields) > 0 && fields[len(fields)-1] == pid {
			count++
		}
	}

	assert.Equal(t, int32(1), count)
}

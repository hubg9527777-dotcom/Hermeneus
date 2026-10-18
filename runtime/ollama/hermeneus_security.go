package server

import (
    "crypto/subtle"
    "net"
    "net/http"
    "os"
    "strings"
    "github.com/gin-gonic/gin"
)

// Hermeneus' private listener accepts only the capability passed by its parent.
// No Origin is accepted, including extensions and null/file origins.
func hermeneusCapabilityMiddleware() gin.HandlerFunc {
    token := os.Getenv("HERMENEUS_OLLAMA_TOKEN")
    return func(c *gin.Context) {
        host, _, err := net.SplitHostPort(c.Request.RemoteAddr)
        peer := net.ParseIP(host)
        headers := c.Request.Header.Values("Authorization")
        expected := "Bearer " + token
        if len(token) < 32 || err != nil || peer == nil || !peer.IsLoopback() ||
            len(c.Request.Header.Values("Origin")) != 0 || len(headers) != 1 ||
            !strings.HasPrefix(headers[0], "Bearer ") ||
            subtle.ConstantTimeCompare([]byte(headers[0]), []byte(expected)) != 1 {
            c.AbortWithStatus(http.StatusForbidden)
            return
        }
        c.Next()
    }
}

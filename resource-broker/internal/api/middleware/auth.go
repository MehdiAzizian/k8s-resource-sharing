package middleware

import (
	"context"
	"crypto/x509"
	"net/http"
)

// contextKey is a custom type for context keys to avoid collisions
type contextKey string

const (
	// ClusterIDKey is the context key for cluster ID
	ClusterIDKey contextKey = "clusterID"
)

// ValidateClientCertificate middleware validates client certificates and extracts cluster ID
func ValidateClientCertificate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Skip auth for healthz endpoint
		if r.URL.Path == "/healthz" {
			next.ServeHTTP(w, r)
			return
		}

		// Extract client certificate from TLS connection
		if r.TLS == nil || len(r.TLS.PeerCertificates) == 0 {
			http.Error(w, "Client certificate required", http.StatusUnauthorized)
			return
		}

		cert := r.TLS.PeerCertificates[0]

		// Extract cluster ID from certificate CN
		clusterID := extractClusterID(cert)
		if clusterID == "" {
			http.Error(w, "Invalid certificate: no cluster ID in CN", http.StatusForbidden)
			return
		}

		// Store cluster ID in request context for downstream handlers
		ctx := context.WithValue(r.Context(), ClusterIDKey, clusterID)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// extractClusterID extracts cluster ID from certificate Common Name
// Certificate CN format: "cluster-abc-123"
func extractClusterID(cert *x509.Certificate) string {
	return cert.Subject.CommonName
}

// GetClusterID retrieves cluster ID from request context
func GetClusterID(ctx context.Context) (string, bool) {
	clusterID, ok := ctx.Value(ClusterIDKey).(string)
	return clusterID, ok
}

// Chain applies middleware in reverse order (last middleware executes first)
func Chain(h http.Handler, middlewares ...func(http.Handler) http.Handler) http.Handler {
	for i := len(middlewares) - 1; i >= 0; i-- {
		h = middlewares[i](h)
	}
	return h
}

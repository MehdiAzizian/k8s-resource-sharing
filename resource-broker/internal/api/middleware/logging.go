package middleware

import (
	"net/http"
	"time"

	"sigs.k8s.io/controller-runtime/pkg/log"
)

// responseWriter wraps http.ResponseWriter to capture status code
type responseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}

// Logging middleware logs HTTP requests with duration and status
func Logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()

		// Wrap response writer to capture status code
		wrapped := &responseWriter{
			ResponseWriter: w,
			statusCode:     http.StatusOK, // default
		}

		// Get cluster ID from context if available
		clusterID, _ := GetClusterID(r.Context())

		// Call next handler
		next.ServeHTTP(wrapped, r)

		// Log request details
		duration := time.Since(start)
		logger := log.FromContext(r.Context()).WithName("http-api")

		logger.Info("HTTP request",
			"method", r.Method,
			"path", r.URL.Path,
			"clusterID", clusterID,
			"status", wrapped.statusCode,
			"duration_ms", duration.Milliseconds(),
			"remote_addr", r.RemoteAddr)
	})
}

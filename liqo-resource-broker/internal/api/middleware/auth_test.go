package middleware

import (
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"net/http"
	"net/http/httptest"
	"testing"
)

// Test: Valid certificate with CN extracts cluster ID correctly
func TestValidateClientCertificate_ValidCertificate(t *testing.T) {
	// Create a mock handler that checks the cluster ID
	var extractedClusterID string
	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		clusterID, ok := GetClusterID(r.Context())
		if ok {
			extractedClusterID = clusterID
		}
		w.WriteHeader(http.StatusOK)
	})

	// Wrap with our middleware
	handler := ValidateClientCertificate(nextHandler)

	// Create request with mock TLS connection
	req := httptest.NewRequest("GET", "/api/v1/advertisements", nil)
	req.TLS = &tls.ConnectionState{
		PeerCertificates: []*x509.Certificate{
			{
				Subject: pkix.Name{
					CommonName: "cluster-1",
				},
			},
		},
	}

	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	// Verify: request succeeded and cluster ID was extracted
	if rr.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d", rr.Code)
	}
	if extractedClusterID != "cluster-1" {
		t.Errorf("expected cluster ID 'cluster-1', got '%s'", extractedClusterID)
	}
}

// Test: Request without TLS connection is rejected
func TestValidateClientCertificate_NoTLSConnection(t *testing.T) {
	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	handler := ValidateClientCertificate(nextHandler)

	// Create request without TLS
	req := httptest.NewRequest("GET", "/api/v1/advertisements", nil)
	req.TLS = nil // no TLS

	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	// Verify: request rejected with 401
	if rr.Code != http.StatusUnauthorized {
		t.Errorf("expected status 401, got %d", rr.Code)
	}
}

// Test: Request with TLS but no peer certificates is rejected
func TestValidateClientCertificate_NoPeerCertificates(t *testing.T) {
	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	handler := ValidateClientCertificate(nextHandler)

	// Create request with TLS but no certificates
	req := httptest.NewRequest("GET", "/api/v1/advertisements", nil)
	req.TLS = &tls.ConnectionState{
		PeerCertificates: []*x509.Certificate{}, // empty
	}

	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	// Verify: request rejected with 401
	if rr.Code != http.StatusUnauthorized {
		t.Errorf("expected status 401, got %d", rr.Code)
	}
}

// Test: Certificate with empty CN is rejected
func TestValidateClientCertificate_EmptyCN(t *testing.T) {
	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	handler := ValidateClientCertificate(nextHandler)

	// Create request with certificate but empty CN
	req := httptest.NewRequest("GET", "/api/v1/advertisements", nil)
	req.TLS = &tls.ConnectionState{
		PeerCertificates: []*x509.Certificate{
			{
				Subject: pkix.Name{
					CommonName: "", // empty CN
				},
			},
		},
	}

	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	// Verify: request rejected with 403
	if rr.Code != http.StatusForbidden {
		t.Errorf("expected status 403, got %d", rr.Code)
	}
}

// Test: Health check endpoint skips authentication
func TestValidateClientCertificate_HealthzSkipsAuth(t *testing.T) {
	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("healthy"))
	})

	handler := ValidateClientCertificate(nextHandler)

	// Create request to healthz without TLS (should still work)
	req := httptest.NewRequest("GET", "/healthz", nil)
	req.TLS = nil // no TLS

	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	// Verify: request succeeds even without certificate
	if rr.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d", rr.Code)
	}
}

// Test: GetClusterID returns false when not set
func TestGetClusterID_NotSet(t *testing.T) {
	req := httptest.NewRequest("GET", "/test", nil)

	clusterID, ok := GetClusterID(req.Context())

	if ok {
		t.Error("expected ok to be false when cluster ID not set")
	}
	if clusterID != "" {
		t.Errorf("expected empty cluster ID, got '%s'", clusterID)
	}
}

// Test: GetClusterID returns correct value when set
func TestGetClusterID_WhenSet(t *testing.T) {
	var capturedClusterID string
	var capturedOK bool

	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedClusterID, capturedOK = GetClusterID(r.Context())
		w.WriteHeader(http.StatusOK)
	})

	handler := ValidateClientCertificate(nextHandler)

	req := httptest.NewRequest("GET", "/api/v1/test", nil)
	req.TLS = &tls.ConnectionState{
		PeerCertificates: []*x509.Certificate{
			{
				Subject: pkix.Name{
					CommonName: "my-cluster-id",
				},
			},
		},
	}

	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	if !capturedOK {
		t.Error("expected ok to be true")
	}
	if capturedClusterID != "my-cluster-id" {
		t.Errorf("expected 'my-cluster-id', got '%s'", capturedClusterID)
	}
}

// Test: Chain applies middlewares in correct order
func TestChain_AppliesMiddlewaresInOrder(t *testing.T) {
	var order []string

	middleware1 := func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			order = append(order, "middleware1-before")
			next.ServeHTTP(w, r)
			order = append(order, "middleware1-after")
		})
	}

	middleware2 := func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			order = append(order, "middleware2-before")
			next.ServeHTTP(w, r)
			order = append(order, "middleware2-after")
		})
	}

	finalHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		order = append(order, "handler")
		w.WriteHeader(http.StatusOK)
	})

	// Chain: middleware1 wraps middleware2 wraps handler
	handler := Chain(finalHandler, middleware1, middleware2)

	req := httptest.NewRequest("GET", "/test", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	// Expected order: m1-before, m2-before, handler, m2-after, m1-after
	expected := []string{
		"middleware1-before",
		"middleware2-before",
		"handler",
		"middleware2-after",
		"middleware1-after",
	}

	if len(order) != len(expected) {
		t.Fatalf("expected %d calls, got %d: %v", len(expected), len(order), order)
	}

	for i, v := range expected {
		if order[i] != v {
			t.Errorf("at position %d: expected '%s', got '%s'", i, v, order[i])
		}
	}
}

// Test: Different cluster IDs in certificates work correctly
func TestValidateClientCertificate_DifferentClusterIDs(t *testing.T) {
	testCases := []struct {
		name       string
		commonName string
	}{
		{"simple name", "cluster-1"},
		{"with dashes", "my-test-cluster-abc"},
		{"with numbers", "cluster123"},
		{"uuid style", "550e8400-e29b-41d4-a716-446655440000"},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			var extractedID string
			nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				extractedID, _ = GetClusterID(r.Context())
				w.WriteHeader(http.StatusOK)
			})

			handler := ValidateClientCertificate(nextHandler)

			req := httptest.NewRequest("GET", "/api/v1/test", nil)
			req.TLS = &tls.ConnectionState{
				PeerCertificates: []*x509.Certificate{
					{
						Subject: pkix.Name{
							CommonName: tc.commonName,
						},
					},
				},
			}

			rr := httptest.NewRecorder()
			handler.ServeHTTP(rr, req)

			if extractedID != tc.commonName {
				t.Errorf("expected '%s', got '%s'", tc.commonName, extractedID)
			}
		})
	}
}

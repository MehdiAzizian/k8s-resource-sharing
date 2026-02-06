package handlers

import (
	"encoding/json"
	"net/http"

	"sigs.k8s.io/controller-runtime/pkg/log"

	brokerv1alpha1 "github.com/mehdiazizian/liqo-resource-broker/api/v1alpha1"
	"github.com/mehdiazizian/liqo-resource-broker/internal/transport/dto"
)

// GetReservations handles GET /api/v1/reservations
// Filters reservations by clusterID and role (requester or provider)
func (h *Handler) GetReservations(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	logger := log.FromContext(ctx).WithName("reservation-handler")

	// Parse query parameters
	clusterID := r.URL.Query().Get("clusterID")
	role := r.URL.Query().Get("role") // "requester" or "provider"

	if clusterID == "" {
		http.Error(w, "Missing clusterID query parameter", http.StatusBadRequest)
		return
	}

	if role != "requester" && role != "provider" {
		http.Error(w, "Invalid role parameter (must be 'requester' or 'provider')",
			http.StatusBadRequest)
		return
	}

	// List all reservations in namespace
	reservationList := &brokerv1alpha1.ReservationList{}
	if err := h.k8sClient.List(ctx, reservationList); err != nil {
		logger.Error(err, "Failed to list reservations")
		http.Error(w, "Failed to list reservations", http.StatusInternalServerError)
		return
	}

	// Filter reservations by cluster and role
	var filtered []*dto.ReservationDTO
	for i := range reservationList.Items {
		rsv := &reservationList.Items[i]

		// Only include reservations in Reserved phase
		if rsv.Status.Phase != brokerv1alpha1.ReservationPhaseReserved {
			continue
		}

		// Filter based on role
		if role == "requester" && rsv.Spec.RequesterID == clusterID {
			filtered = append(filtered, dto.FromReservation(rsv))
		} else if role == "provider" && rsv.Spec.TargetClusterID == clusterID {
			filtered = append(filtered, dto.FromReservation(rsv))
		}
	}

	logger.Info("Retrieved reservations",
		"clusterID", clusterID,
		"role", role,
		"count", len(filtered))

	// Return reservations
	response := map[string]interface{}{
		"reservations": filtered,
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(response); err != nil {
		logger.Error(err, "Failed to encode response")
	}
}

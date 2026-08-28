package store

import "time"

// ---- Memory Web Push operations ----

func (s *MemoryStore) UpsertPushSubscription(subscription *PushSubscription) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	byEndpoint := s.pushSubscriptions[subscription.UserID]
	if byEndpoint == nil {
		byEndpoint = make(map[string]*PushSubscription)
		s.pushSubscriptions[subscription.UserID] = byEndpoint
	}
	createdAt := now
	if existing := byEndpoint[subscription.Endpoint]; existing != nil {
		createdAt = existing.CreatedAt
	}
	copy := *subscription
	copy.CreatedAt = createdAt
	copy.UpdatedAt = now
	byEndpoint[subscription.Endpoint] = &copy
	return nil
}

func (s *MemoryStore) DeletePushSubscription(userID, endpoint string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	byEndpoint := s.pushSubscriptions[userID]
	delete(byEndpoint, endpoint)
	if len(byEndpoint) == 0 {
		delete(s.pushSubscriptions, userID)
	}
	return nil
}

func (s *MemoryStore) GetPushSubscriptions(userID string) ([]*PushSubscription, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	byEndpoint := s.pushSubscriptions[userID]
	result := make([]*PushSubscription, 0, len(byEndpoint))
	for _, subscription := range byEndpoint {
		copy := *subscription
		result = append(result, &copy)
	}
	return result, nil
}

// ---- SQLite Web Push operations ----

func (s *SQLiteStore) UpsertPushSubscription(subscription *PushSubscription) error {
	_, err := s.db.Exec(`
		INSERT INTO push_subscriptions (user_id, endpoint, p256dh, auth, updated_at)
		VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
		ON CONFLICT(user_id, endpoint) DO UPDATE SET
			p256dh = excluded.p256dh,
			auth = excluded.auth,
			updated_at = CURRENT_TIMESTAMP`,
		subscription.UserID, subscription.Endpoint, subscription.P256DH, subscription.Auth,
	)
	return err
}

func (s *SQLiteStore) DeletePushSubscription(userID, endpoint string) error {
	_, err := s.db.Exec(
		"DELETE FROM push_subscriptions WHERE user_id = ? AND endpoint = ?",
		userID, endpoint,
	)
	return err
}

func (s *SQLiteStore) GetPushSubscriptions(userID string) ([]*PushSubscription, error) {
	rows, err := s.db.Query(`
		SELECT user_id, endpoint, p256dh, auth, created_at, updated_at
		FROM push_subscriptions WHERE user_id = ?`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var result []*PushSubscription
	for rows.Next() {
		subscription := &PushSubscription{}
		if err := rows.Scan(
			&subscription.UserID,
			&subscription.Endpoint,
			&subscription.P256DH,
			&subscription.Auth,
			&subscription.CreatedAt,
			&subscription.UpdatedAt,
		); err != nil {
			return nil, err
		}
		result = append(result, subscription)
	}
	return result, rows.Err()
}

// ---- PostgreSQL Web Push operations ----

func (s *PostgresStore) UpsertPushSubscription(subscription *PushSubscription) error {
	_, err := s.db.Exec(`
		INSERT INTO push_subscriptions (user_id, endpoint, p256dh, auth, updated_at)
		VALUES ($1, $2, $3, $4, NOW())
		ON CONFLICT(user_id, endpoint) DO UPDATE SET
			p256dh = EXCLUDED.p256dh,
			auth = EXCLUDED.auth,
			updated_at = NOW()`,
		subscription.UserID, subscription.Endpoint, subscription.P256DH, subscription.Auth,
	)
	return err
}

func (s *PostgresStore) DeletePushSubscription(userID, endpoint string) error {
	_, err := s.db.Exec(
		"DELETE FROM push_subscriptions WHERE user_id = $1 AND endpoint = $2",
		userID, endpoint,
	)
	return err
}

func (s *PostgresStore) GetPushSubscriptions(userID string) ([]*PushSubscription, error) {
	rows, err := s.db.Query(`
		SELECT user_id, endpoint, p256dh, auth, created_at, updated_at
		FROM push_subscriptions WHERE user_id = $1`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var result []*PushSubscription
	for rows.Next() {
		subscription := &PushSubscription{}
		if err := rows.Scan(
			&subscription.UserID,
			&subscription.Endpoint,
			&subscription.P256DH,
			&subscription.Auth,
			&subscription.CreatedAt,
			&subscription.UpdatedAt,
		); err != nil {
			return nil, err
		}
		result = append(result, subscription)
	}
	return result, rows.Err()
}

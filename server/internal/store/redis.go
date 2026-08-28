package store

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

// RedisCache provides caching and pub/sub for the IM server.
type RedisCache struct {
	client *redis.Client
	ctx    context.Context
}

// NewRedisCache creates a new Redis cache.
func NewRedisCache(addr, password string, db int) (*RedisCache, error) {
	client := redis.NewClient(&redis.Options{
		Addr:     addr,
		Password: password,
		DB:       db,
	})

	ctx := context.Background()
	if err := client.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("failed to connect to Redis: %w", err)
	}

	return &RedisCache{
		client: client,
		ctx:    ctx,
	}, nil
}

// Close closes the Redis connection.
func (r *RedisCache) Close() error {
	return r.client.Close()
}

// ---- Online Status ----

// SetUserOnline marks a user as online.
func (r *RedisCache) SetUserOnline(userID string) error {
	key := fmt.Sprintf("online:%s", userID)
	return r.client.Set(r.ctx, key, "1", 5*time.Minute).Err()
}

// SetUserOffline marks a user as offline.
func (r *RedisCache) SetUserOffline(userID string) error {
	key := fmt.Sprintf("online:%s", userID)
	return r.client.Del(r.ctx, key).Err()
}

// IsUserOnline checks if a user is online.
func (r *RedisCache) IsUserOnline(userID string) (bool, error) {
	key := fmt.Sprintf("online:%s", userID)
	exists, err := r.client.Exists(r.ctx, key).Result()
	if err != nil {
		return false, err
	}
	return exists > 0, nil
}

// RefreshOnline extends the online status TTL.
func (r *RedisCache) RefreshOnline(userID string) error {
	key := fmt.Sprintf("online:%s", userID)
	return r.client.Expire(r.ctx, key, 5*time.Minute).Err()
}

// ---- Unread Count ----

// IncrementUnread increments the unread count for a user in a conversation.
func (r *RedisCache) IncrementUnread(convID, userID string) (int64, error) {
	key := fmt.Sprintf("unread:%s:%s", convID, userID)
	return r.client.Incr(r.ctx, key).Result()
}

// GetUnread gets the unread count for a user in a conversation.
func (r *RedisCache) GetUnread(convID, userID string) (int64, error) {
	key := fmt.Sprintf("unread:%s:%s", convID, userID)
	val, err := r.client.Get(r.ctx, key).Int64()
	if err == redis.Nil {
		return 0, nil
	}
	return val, err
}

// ClearUnread clears the unread count for a user in a conversation.
func (r *RedisCache) ClearUnread(convID, userID string) error {
	key := fmt.Sprintf("unread:%s:%s", convID, userID)
	return r.client.Del(r.ctx, key).Err()
}

// ---- Session Cache ----

// CacheUser caches user info.
func (r *RedisCache) CacheUser(userID string, user *User) error {
	key := fmt.Sprintf("user:%s", userID)
	data, err := json.Marshal(user)
	if err != nil {
		return err
	}
	return r.client.Set(r.ctx, key, data, 10*time.Minute).Err()
}

// GetCachedUser gets cached user info.
func (r *RedisCache) GetCachedUser(userID string) (*User, error) {
	key := fmt.Sprintf("user:%s", userID)
	data, err := r.client.Get(r.ctx, key).Bytes()
	if err == redis.Nil {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	user := &User{}
	if err := json.Unmarshal(data, user); err != nil {
		return nil, err
	}
	return user, nil
}

// ---- Conversation Cache ----

// CacheConversations caches the conversation list for a user.
func (r *RedisCache) CacheConversations(userID string, convs []*Conversation) error {
	key := fmt.Sprintf("convs:%s", userID)
	data, err := json.Marshal(convs)
	if err != nil {
		return err
	}
	return r.client.Set(r.ctx, key, data, 2*time.Minute).Err()
}

// GetCachedConversations gets cached conversations.
func (r *RedisCache) GetCachedConversations(userID string) ([]*Conversation, error) {
	key := fmt.Sprintf("convs:%s", userID)
	data, err := r.client.Get(r.ctx, key).Bytes()
	if err == redis.Nil {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var convs []*Conversation
	if err := json.Unmarshal(data, &convs); err != nil {
		return nil, err
	}
	return convs, nil
}

// InvalidateConversations invalidates the conversation cache for a user.
func (r *RedisCache) InvalidateConversations(userID string) error {
	key := fmt.Sprintf("convs:%s", userID)
	return r.client.Del(r.ctx, key).Err()
}

// ---- Pub/Sub for multi-instance support ----

// Publish publishes a message to a channel.
func (r *RedisCache) Publish(channel string, message interface{}) error {
	data, err := json.Marshal(message)
	if err != nil {
		return err
	}
	return r.client.Publish(r.ctx, channel, data).Err()
}

// Subscribe subscribes to a channel.
func (r *RedisCache) Subscribe(channel string) *redis.PubSub {
	return r.client.Subscribe(r.ctx, channel)
}

// ---- Rate Limiting ----

// CheckRateLimit checks if a request is allowed (sliding window).
// Returns true if allowed, false if rate limited.
func (r *RedisCache) CheckRateLimit(key string, limit int, window time.Duration) (bool, error) {
	now := time.Now().UnixMilli()
	windowStart := now - window.Milliseconds()

	pipe := r.client.Pipeline()
	pipe.ZRemRangeByScore(r.ctx, key, "0", fmt.Sprintf("%d", windowStart))
	pipe.ZAdd(r.ctx, key, redis.Z{Score: float64(now), Member: now})
	pipe.ZCard(r.ctx, key)
	pipe.Expire(r.ctx, key, window)
	cmds, err := pipe.Exec(r.ctx)
	if err != nil {
		return false, err
	}

	count := cmds[2].(*redis.IntCmd).Val()
	return count <= int64(limit), nil
}

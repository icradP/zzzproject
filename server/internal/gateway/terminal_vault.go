package gateway

import (
	"errors"
	"strings"

	"github.com/icradp/zzz-im-server/internal/protocol"
	"github.com/icradp/zzz-im-server/internal/store"
)

const maxTerminalVaultPayloadBytes = 4 * 1024 * 1024

func (g *Gateway) handleGetTerminalVault(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	vault, err := g.store.GetTerminalVault(client.userID)
	if err != nil {
		g.sendError(client, req.Echo, "failed to load terminal vault")
		return
	}
	if vault == nil {
		g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Data: map[string]interface{}{"revision": 0}, Echo: req.Echo})
		return
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Data: vault, Echo: req.Echo})
}

func (g *Gateway) handlePutTerminalVault(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid terminal vault params")
		return
	}
	payload, payloadOK := params["payload"].(string)
	expected, revisionOK := params["expected_revision"].(float64)
	if !payloadOK || strings.TrimSpace(payload) == "" || len(payload) > maxTerminalVaultPayloadBytes {
		g.sendError(client, req.Echo, "terminal vault payload must contain 1-4194304 bytes")
		return
	}
	if !revisionOK || expected < 0 || expected != float64(int64(expected)) {
		g.sendError(client, req.Echo, "terminal vault expected_revision is invalid")
		return
	}
	vault, err := g.store.PutTerminalVault(client.userID, payload, int64(expected))
	if errors.Is(err, store.ErrTerminalVaultConflict) {
		currentRevision := int64(0)
		if vault != nil {
			currentRevision = vault.Revision
		}
		g.sendJSON(client, protocol.Response{Status: "failed", RetCode: 409, Msg: "terminal vault revision conflict", Data: map[string]interface{}{"revision": currentRevision}, Echo: req.Echo})
		return
	}
	if err != nil {
		g.sendError(client, req.Echo, "failed to save terminal vault")
		return
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Data: vault, Echo: req.Echo})
}

func (g *Gateway) handleDeleteTerminalVault(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	if err := g.store.DeleteTerminalVault(client.userID); err != nil {
		g.sendError(client, req.Echo, "failed to delete terminal vault")
		return
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Echo: req.Echo})
}

package fairy

import "regexp"

var sensitiveCredentialPatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?i)-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----`),
	regexp.MustCompile(`(?i)\bauthorization\s*[:=]\s*bearer\s+[a-z0-9._~+/=-]{8,}`),
	regexp.MustCompile(`(?i)\b(?:password|passwd|pwd|api[_-]?key|access[_-]?token|session[_-]?token|secret[_-]?key)\b\s*[:=]\s*["']?[^\s"';]{6,}`),
	regexp.MustCompile(`(?i)\b(?:cookie|set-cookie)\s*[:=]\s*["']?[^;\s=]+=[^;\s]{12,}`),
	regexp.MustCompile(`(?i)\b(?:ltuid(?:_v2)?|ltoken(?:_v2)?|cookie_token(?:_v2)?|account_id(?:_v2)?|stoken(?:_v2)?|login_ticket)\b\s*=\s*[^;\s]{6,}`),
	regexp.MustCompile(`(?:密码|口令|API[ _-]?密钥|访问令牌|会话令牌|密钥|令牌)\s*[:：=]\s*["']?[^\s"'；;]{6,}`),
	regexp.MustCompile(`(?i)\b(?:sk-(?:proj-|svcacct-)?[a-z0-9_-]{16,}|github_pat_[a-z0-9_]{20,}|gh[pousr]_[a-z0-9]{20,}|xox[baprs]-[a-z0-9-]{10,}|AKIA[0-9A-Z]{16})\b`),
}

func containsSensitiveCredential(text string) bool {
	for _, pattern := range sensitiveCredentialPatterns {
		if pattern.MatchString(text) {
			return true
		}
	}
	return false
}

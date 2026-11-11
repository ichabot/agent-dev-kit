#!/usr/bin/env bash
# SSH public key validation shared by the agent-dev-kit scripts.
#
#   adk_read_pubkey FILE      print the key as one normalized line "type base64 [comment]";
#                             on failure print the reason to stderr and return 1
#   adk_pubkey_material LINE  print "type base64" (identity of a key, comment ignored)
#   adk_pubkey_fingerprint LINE  print the SHA256 fingerprint of a key line
#
# Accepted: exactly one plain key line (no authorized_keys options), modern key types,
# printable ASCII only (the line ends up in YAML and in root-owned key files).
# shellcheck disable=SC2034  # ADK_FINGERPRINT_RE is used by the callers

ADK_PUBKEY_TYPES='ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-nistp(256|384|521)|sk-ecdsa-sha2-nistp256@openssh\.com|ssh-rsa'
ADK_FINGERPRINT_RE='^SHA256:[A-Za-z0-9+/]{43}$'

adk_pubkey_fingerprint() {
  local out
  out="$(ssh-keygen -l -f - <<< "$1" 2>/dev/null)" || return 1
  out="${out#* }"
  printf '%s\n' "${out%% *}"
}

adk_pubkey_material() {
  local type rest
  type="${1%% *}"
  rest="${1#* }"
  printf '%s %s\n' "$type" "${rest%% *}"
}

adk_read_pubkey() {
  local file="$1" content line="" n=0 l bits
  local LC_ALL=C   # [[:print:]] must not match non-ASCII
  if [[ ! -f "$file" || ! -r "$file" ]]; then
    echo "ERROR: cannot read public key file: $file" >&2
    return 2
  fi
  content="$(tr -d '\r' < "$file")"
  if [[ "$content" == *"PRIVATE KEY"* ]]; then
    echo "ERROR: $file is a private key; pass the .pub file" >&2
    return 1
  fi
  while IFS= read -r l; do
    l="${l#"${l%%[![:space:]]*}"}"
    l="${l%"${l##*[![:space:]]}"}"
    [[ -z "$l" || "$l" == \#* ]] && continue
    n=$((n + 1))
    line="$l"
  done <<< "$content"
  if ((n != 1)); then
    echo "ERROR: $file must contain exactly one public key (found $n)" >&2
    return 1
  fi
  if [[ ! "$line" =~ ^[[:print:]]+$ ]]; then
    echo "ERROR: $file contains non-printable or non-ASCII characters" >&2
    return 1
  fi
  if [[ ! "$line" =~ ^($ADK_PUBKEY_TYPES)\ AAAA[A-Za-z0-9+/]+={0,3}(\ .*)?$ ]]; then
    echo "ERROR: $file is not a plain public key line (type base64 [comment], no options)" >&2
    return 1
  fi
  if ! bits="$(ssh-keygen -l -f - <<< "$line" 2>/dev/null)"; then
    echo "ERROR: ssh-keygen rejects the key in $file" >&2
    return 1
  fi
  if [[ "$line" == ssh-rsa\ * ]] && ((${bits%% *} < 3072)); then
    echo "ERROR: RSA keys need at least 3072 bits (use ed25519)" >&2
    return 1
  fi
  printf '%s\n' "$line"
}

//
//  Secrets.example.swift
//  TEMPLATE — copy this to watch/Sources/Secrets.swift and fill in your values.
//
//  watch/Sources/Secrets.swift is GITIGNORED and must NEVER be committed: the token is
//  effectively an RCE password (see infra/SECURITY.md). This file (the template, with
//  placeholders) is the only one that's checked in.
//
//  Fastest path: run ./setup.sh — it creates watch/Sources/Secrets.swift from this file
//  and injects the PINCH_TOKEN from backend/.env automatically.
//
//  Fields:
//   - serverURL: your tunnel URL, e.g. wss://agent.yourdomain.com — or the ephemeral
//     ngrok / quick-tunnel host that pinch-up.sh prints. (The watch transport rewrites
//     wss:// → https:// internally.)
//   - token:     the PINCH_TOKEN from backend/.env. Must match the backend exactly.
//
enum Secrets {
    static let serverURL = "wss://your-tunnel-host"
    static let token = "PASTE_YOUR_PINCH_TOKEN_HERE"
}

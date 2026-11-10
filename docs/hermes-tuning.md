# Hermes tuning: disable what a dev server does not need

Every enabled skill adds its name and description to the system prompt, and every
enabled toolset adds its tool schemas. On a headless dev server most of the creative,
personal-productivity and messaging parts are dead weight. Tool schemas are the bigger
cost; skills are cheaper per entry but add up.

Checked against Hermes Agent source of 2026-11-05 (44 bundled skills).
Re-check after major Hermes updates: `hermes skills list`, `hermes tools list`.

## Skills

### Disable

| Skill | Reason |
|---|---|
| `ascii-video`, `manim-video`, `p5js`, `baoyu-infographic`, `songwriting-and-ai-music` | Creative media, not app development |
| `humanizer` | Text styling |
| `youtube-content`, `xurl` | Social media |
| `arxiv`, `competitor-news-monitor` | Research / news monitoring |
| `email-inbox-triage`, `himalaya` | Mail client work |
| `google-workspace`, `teams-meeting-pipeline`, `meeting-action-items`, `document-to-action-items`, `weekly-review-planning`, `product-price-monitor`, `maps` | Personal productivity |
| `obsidian` | Note vault on a desktop |
| `codex` | Delegates to OpenAI Codex CLI, no OpenAI account here |
| `claude-code` | Delegates to the Claude Code CLI; the CLI would run on a subscription login, which is not meant for automation inside another agent |
| `github` | Projects live in Gitea, not GitHub |
| `sdlc-review` | Kanban handoffs; kanban toolset stays off |

### Hidden automatically on Linux (no action)

`apple-notes`, `apple-reminders`, `findmy`, `imessage`, `computer-use` (macOS only).

### Keep

`hermes-agent` (essential, cannot be disabled), `test-driven-development`,
`systematic-debugging`, `requesting-code-review`, `simplify-code`, `spike`,
`codebase-inspection`, `dogfood` (browser QA of the web apps), `claude-design`
(UI prototypes), `architecture-diagram` (docs), `grounded-citations` (checking docs),
`blocked-page-recovery`, `pdf`, `microsoft-office` (customer documents),
`popular-web-designs` (optional: only if the customer wants design references).

### Command

```bash
hermes config set skills.disabled '[ascii-video, manim-video, p5js, baoyu-infographic, songwriting-and-ai-music, humanizer, youtube-content, xurl, arxiv, competitor-news-monitor, email-inbox-triage, himalaya, google-workspace, teams-meeting-pipeline, meeting-action-items, document-to-action-items, weekly-review-planning, product-price-monitor, maps, obsidian, codex, claude-code, github, sdlc-review]'
```

## Toolsets

### Disable

| Toolset | Reason |
|---|---|
| `image_gen`, `video`, `video_gen`, `tts`, `stt` | Media generation / audio |
| `x_search` | Social media |
| `computer_use` | No desktop on the server |
| `kanban` | Not used |
| `homeassistant`, `yuanbao` | Unrelated integrations |
| `a2a` | Agent-to-agent bridge, not used |
| `connections` | Hosted app connectors (Gmail, Notion, …), not used |

### Keep

`terminal`, `file`, `code_execution`, `web`, `browser` (UI tests), `vision`
(screenshots), `skills`, `memory`, `session_search`, `context_engine`, `todo`,
`clarify`, `delegation`, `cronjob`.

### Command

```bash
hermes config set agent.disabled_toolsets '[image_gen, video, video_gen, tts, stt, x_search, computer_use, kanban, homeassistant, yuanbao, a2a, connections]'
```

`agent.disabled_toolsets` applies to every surface (CLI, desktop, gateway) and wins
over per-platform settings.

## Verify

```bash
hermes skills list      # disabled skills are marked
hermes tools list       # toolsets above show as disabled
hermes doctor
```

Restart the gateway afterwards so running sessions pick up the change.

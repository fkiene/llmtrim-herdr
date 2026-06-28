# VHS tape to capture herdr with the llmtrim savings badge for the README.
#
# Run from the repo ROOT (the plugin is linked from $PWD):
#   vhs assets/herdr-capture.tape
#
# It builds the scene with herdr's CLI in an isolated session ("llmtrim-demo"),
# so it never touches your real workspaces and the result is deterministic:
# ONE named space, a "claude" tab, claude running in the main (left) pane with
# the live llmtrim badge beside it in the sidebar, and the `llmtrim status`
# dashboard split to the right. The deliverable is the PNG from `Screenshot`.
# (VHS also drops its default out.gif in the working dir; ignore or delete it.)
#
# Prereqs:
#   - herdr + llmtrim on PATH, claude logged in
#   - the llmtrim daemon running with some traffic, so the badge has a number
#     (the badge reads the global ledger, so prior usage is enough)
#
# Key ordering, learned the hard way: plugins are per-session and the savings
# poller starts on workspace.created. So we (1) link the plugin into the
# session, (2) THEN create the workspace, and (3) run claude in that workspace's
# main pane -- the pane the poller watches and tags with the badge.

# --- Framing: a clean window, minimal padding, no outer margin. --------------
Set Theme "Catppuccin Mocha"
Set FontSize 16
Set Width 1800
# Shorter than the full conversation on purpose: claude pins to the latest
# message, so the welcome box and the question scroll off the TOP, leaving just
# the answer + input in view. Nudge DOWN if the question still peeks; nudge UP
# if the right-hand llmtrim dashboard loses its bottom rows.
Set Height 640
Set Padding 10
Set WindowBar Colorful
Set WindowBarSize 32
Set CursorBlink false
Set TypingSpeed 30ms

# --- Build the scene off-screen via the CLI. ---------------------------------
# `Hide` keeps setup out of the recording; the final Screenshot shows the TUI.
Hide

# Clear any session left over from a previous run.
Type `herdr session stop llmtrim-demo 2>/dev/null; herdr session delete llmtrim-demo 2>/dev/null; true`
Enter
Sleep 1s

# Start the session server in the background. Its foreground client has no PTY
# here and exits; the server stays up (output parked in a log).
Type `herdr --session llmtrim-demo >/tmp/herdr-demo.log 2>&1 & sleep 3`
Enter
Sleep 3s

# 1. Link the plugin into THIS session (run from the repo root so $PWD is it).
Type `herdr --session llmtrim-demo plugin link "$PWD"`
Enter
Sleep 1s

# 2. Create the workspace AFTER linking, so workspace.created forks the poller.
#    A fresh session already holds w1 (created before the link, no poller), so
#    the new one is w2; we close w1 to keep exactly one space.
Type `herdr --session llmtrim-demo workspace create --label "llmtrim demo" --focus`
Enter
Sleep 2s
Type `herdr --session llmtrim-demo workspace close w1`
Enter
Sleep 1s
Type `herdr --session llmtrim-demo tab rename w2:t1 "claude"`
Enter
Sleep 1s

# 3. Launch claude in w2's MAIN pane (w2:p1) -- the poller's pane -- so the badge
#    shows beside the agent and claude fills the main pane, not a split.
#    --dangerously-skip-permissions so claude answers without stopping on the
#    "allow fetch?" prompt. Adjust to however your herdr integration launches it.
Type `herdr --session llmtrim-demo pane run w2:p1 "claude --dangerously-skip-permissions"`
Enter
Sleep 8s

# 4. Ask a question in the claude conversation so the pane shows real content.
#    Type the text, then send a SEPARATE Enter keystroke -- `pane run` pastes
#    "text\n" as one chunk and claude treats the newline as paste content, not a
#    submit, so the question would just sit unsent. A discrete send-keys Enter
#    is a real key press that submits it.
Type `herdr --session llmtrim-demo pane send-text w2:p1 "Why use https://github.com/fkiene/llmtrim? Be brief (respond as a marketing person, we need to promote the product)"`
Enter
Sleep 1s
Type `herdr --session llmtrim-demo pane send-keys w2:p1 Enter`
Enter
Sleep 12s

# 5. Open the `llmtrim status` dashboard as a right-hand split, then focus claude
#    back so the conversation pane is the active one in the shot.
Type `herdr --session llmtrim-demo plugin action invoke open-dashboard --plugin llmtrim.proxy`
Enter
Sleep 4s
Type `herdr --session llmtrim-demo pane focus --direction left`
Enter
Sleep 1s

Show

# --- Attach the TUI to display the scene, then settle. ------------------------
Type "herdr --session llmtrim-demo"
Enter
Sleep 6s

# --- Capture the still for the README. ---------------------------------------
Screenshot assets/herdr-llmtrim.png

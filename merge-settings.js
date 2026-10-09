// Claude Ping — add/remove its hooks in ~/.claude/settings.json without touching anything else.
// Run with:  osascript -l JavaScript merge-settings.js <path to settings.json> [--remove]
// (JavaScript for Automation ships with macOS, so no Node or Python is needed.)

const MARK = 'claude-ping.sh';
const HOOK_CMD = '"$HOME/.claude/hooks/claude-ping.sh" ';
const USAGE_MARK = 'claude-usage.sh';

function buildHooks() {
  const cmd = (ev) => ({ type: 'command', command: HOOK_CMD + ev, async: true, timeout: 10 });
  return {
    Stop:             [{ hooks: [cmd('stop')] }],
    StopFailure:      [{ hooks: [cmd('error')] }],
    Notification:     [{ matcher: 'permission_prompt|elicitation_dialog|agent_needs_input', hooks: [cmd('notify')] }],
    PreToolUse:       [{ matcher: 'AskUserQuestion', hooks: [cmd('ask')] }],
    UserPromptSubmit: [{ hooks: [cmd('prompt')] }],
    SessionEnd:       [{ hooks: [cmd('end')] }],
  };
}

function isOurs(h) {
  return h && typeof h.command === 'string' && h.command.indexOf(MARK) !== -1;
}

// Pure (no I/O) so it can be tested.
function mergeSettings(settings, remove) {
  if (settings === null || typeof settings !== 'object' || Array.isArray(settings)) {
    throw new Error('settings.json must be a JSON object');
  }
  const hooks = (settings.hooks && typeof settings.hooks === 'object') ? settings.hooks : {};

  // 1) Drop old Claude Ping entries (reinstalling never creates duplicates).
  for (const ev of Object.keys(hooks)) {
    if (!Array.isArray(hooks[ev])) continue;
    const kept = [];
    for (const group of hooks[ev]) {
      if (!group || !Array.isArray(group.hooks)) { kept.push(group); continue; }
      const rest = group.hooks.filter((h) => !isOurs(h));
      if (rest.length === 0 && group.hooks.length > 0) continue; // the group only held our hooks
      kept.push(Object.assign({}, group, { hooks: rest }));
    }
    if (kept.length) hooks[ev] = kept; else delete hooks[ev];
  }

  // 2) Add the new ones.
  if (!remove) {
    const add = buildHooks();
    for (const ev of Object.keys(add)) {
      hooks[ev] = (Array.isArray(hooks[ev]) ? hooks[ev] : []).concat(add[ev]);
    }
  }

  if (Object.keys(hooks).length) settings.hooks = hooks; else delete settings.hooks;

  // 3) An earlier version installed a statusLine for the usage meter; it is no longer used.
  //    Remove it only if it belongs to Claude Ping. Your own status line is never touched.
  const sl = settings.statusLine;
  if (sl && typeof sl.command === 'string' && sl.command.indexOf(USAGE_MARK) !== -1) delete settings.statusLine;
  return settings;
}

function run(argv) {
  ObjC.import('Foundation');
  const path = argv[0];
  const remove = argv[1] === '--remove';
  if (!path) throw new Error('Usage: merge-settings.js <settings.json> [--remove]');

  const fm = $.NSFileManager.defaultManager;
  let settings = {};
  if (fm.fileExistsAtPath(path)) {
    const s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
    const text = s.isNil() ? '' : ObjC.unwrap(s);
    if (text.trim()) settings = JSON.parse(text);   // broken JSON → stop, the file is left untouched
  } else {
    const dir = $(path).stringByDeletingLastPathComponent;
    fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(dir, true, $(), null);
  }

  const out = JSON.stringify(mergeSettings(settings, remove), null, 2) + '\n';
  const ok = $(out).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
  if (!ok) throw new Error('Could not write ' + path);
  return remove ? 'Claude Ping hooks removed' : 'Claude Ping hooks installed';
}

if (typeof module !== 'undefined') module.exports = { mergeSettings, buildHooks };

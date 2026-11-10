/// Whether a command an agent wants to run only reads, so it may run without
/// asking the user.
///
/// Deny by default: a command counts as read-only only when MesTerm knows it
/// as such. Anything it does not know, anything that chains or redirects,
/// and anything typed at a configuration prompt is a change, and the user is
/// asked. The agent also says what it means to do (see `send_command`'s
/// `intent`); a command runs unasked only when both sides call it a read.
library;

/// Why a command is not taken as read-only. Shown to the user in the
/// approval dialog.
enum ChangeReason {
  /// The agent said it means to change something.
  agentSaysChange,

  /// The session's prompt is a configuration prompt.
  configMode,

  /// `;`, `&&`, `>`, a backtick and the like: more than one command, or a
  /// file written.
  chained,

  /// Not a command MesTerm knows as read-only.
  unknown,
}

class CommandCheck {
  const CommandCheck.read() : reason = null;
  const CommandCheck.change(ChangeReason this.reason);

  /// Null for a read-only command.
  final ChangeReason? reason;
  bool get readOnly => reason == null;
}

/// Commands that only show something, on network devices (Cisco, Aruba,
/// Huawei, Fortinet, Palo Alto, Juniper...) and on Linux and Windows hosts.
/// Those that can also change something with the right arguments are in
/// [_guarded] instead.
const _readOnly = {
  // Network devices.
  'show', 'sh', 'sho', 'display', 'dis', 'disp', 'get', 'ping', 'traceroute', 'tracert', 'tracepath',
  // Linux.
  'ls', 'll', 'cat', 'head', 'tail', 'grep', 'egrep', 'fgrep', 'zgrep', 'zcat', 'df', 'du', 'free',
  'uptime', 'uname', 'whoami', 'id', 'pwd', 'w', 'who', 'last', 'ps', 'netstat', 'ss', 'lsblk', 'lscpu',
  'lsusb', 'lspci', 'lsmod', 'lsof', 'env', 'printenv', 'which', 'whereis', 'file', 'stat', 'wc',
  'md5sum', 'sha1sum', 'sha256sum', 'nslookup', 'dig', 'host', 'vmstat', 'iostat', 'mpstat', 'nproc',
  'getent', 'groups', 'locale', 'echo', 'test', 'blkid', 'lsattr', 'readlink', 'realpath',
  'basename', 'dirname', 'cut', 'sort', 'uniq',
  // Windows.
  'dir', 'type', 'systeminfo', 'tasklist', 'whoami.exe', 'ipconfig.exe',
};

/// Read-only only in the forms these checks allow.
final Map<String, bool Function(List<String> args)> _guarded = {
  // `hostname NAME` and `date -s` set them.
  'hostname': (a) => a.isEmpty,
  'date': (a) => a.every((x) => x.startsWith('+')),
  'dmesg': (a) => !a.any((x) => x == '-c' || x == '-C' || x.startsWith('--clear') || x == '-D' || x == '-E'),
  'arp': (a) => !a.any((x) => x == '-d' || x == '-s' || x == '-f'),
  'ifconfig': (a) => a.length <= 1 || (a.length == 2 && a[1] == '-a'),
  'ip': (a) => !a.any(_mutatingVerbs.contains),
  'route': (a) => !a.any(_mutatingVerbs.contains),
  'systemctl': (a) => a.isNotEmpty && const {'status', 'list-units', 'list-unit-files', 'list-timers', 'is-active', 'is-enabled', 'is-failed', 'show', 'cat', '--failed'}.contains(a.first),
  'journalctl': (a) => !a.any((x) => x.startsWith('--vacuum') || x == '--rotate' || x == '--flush' || x == '--sync'),
  'find': (a) => !a.any((x) => const {'-delete', '-exec', '-execdir', '-ok', '-okdir', '-fprint', '-fprintf', '-fls'}.contains(x)),
  'ipconfig': (a) => a.every((x) => x.toLowerCase() == '/all' || x.toLowerCase() == '/displaydns'),
  'timedatectl': (a) => a.isEmpty || const {'status', 'show', 'list-timezones'}.contains(a.first),
  'hostnamectl': (a) => a.isEmpty || a.first == 'status',
  'ethtool': (a) => !a.any((x) => x.startsWith('-') && x != '-i' && x != '-S' && x != '-k' && x != '-a' && x != '-g' && x != '-l' && x != '-c' && x != '-m' && x != '--show-features'),
  // Paging only: Cisco `terminal length 0`, Palo Alto `set cli pager off`,
  // Huawei `screen-length 0 temporary`.
  'terminal': (a) => a.isNotEmpty && const {'length', 'width', 'len', 'pager'}.contains(a.first),
  'set': (a) => a.length >= 2 && a[0] == 'cli' && a[1] == 'pager',
  'screen-length': (a) => a.contains('temporary'),
};

const _mutatingVerbs = {
  'add', 'del', 'delete', 'set', 'flush', 'change', 'replace', 'append', 'prepend', 'up', 'down',
  'start', 'stop', 'restart', 'reload', 'enable', 'disable', 'mask', 'kill', 'save', 'restore',
};

/// What may follow a `|`: filters that only cut down what is shown.
const _pipeFilters = {
  'include', 'inc', 'i', 'exclude', 'exc', 'e', 'begin', 'b', 'section', 'sec', 's', 'count', 'grep',
  'egrep', 'match', 'except', 'find', 'no-more', 'display', 'json', 'xml', 'head', 'tail', 'wc', 'sort',
  'uniq', 'cut', 'last', 'trim', 'resolve', 'tr', 'column', 'nl',
};

/// More than one command, a file written, or something run inside it.
final _chaining = RegExp(r'[;&<>`]|\$\(|\$\{|\|\|');

CommandCheck classifyCommand(String command) {
  final text = command.trim();
  if (text.isEmpty) return const CommandCheck.change(ChangeReason.unknown);
  if (_chaining.hasMatch(text)) return const CommandCheck.change(ChangeReason.chained);
  final segments = text.split('|');
  final words = _words(segments.first);
  if (words.isEmpty) return const CommandCheck.change(ChangeReason.unknown);
  final head = words.first.toLowerCase();
  final args = words.skip(1).toList();
  final ok = _readOnly.contains(head) || (_guarded[head]?.call(args) ?? false);
  if (!ok) return const CommandCheck.change(ChangeReason.unknown);
  for (final filter in segments.skip(1)) {
    final f = _words(filter);
    if (f.isEmpty || !_pipeFilters.contains(f.first.toLowerCase())) {
      return const CommandCheck.change(ChangeReason.chained);
    }
  }
  return const CommandCheck.read();
}

List<String> _words(String s) => s.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

/// Prompts that mean the device is taking configuration: Cisco and Aruba
/// `(config)#`, Fortinet `(interface) #`, Huawei and H3C `[NAME]`, Palo
/// Alto and Juniper `user@host#`.
final _configPrompts = [
  RegExp(r'\([^)]*\)\s*#\s*$'),
  RegExp(r'^\[~?\*?[^\]\s][^\]]*\]\s*$'),
  RegExp(r'^[\w.\-]+@[\w.\-]+#\s*$'),
  RegExp(r'^\[edit[^\]]*\]'),
];

bool isConfigPrompt(String line) {
  final l = line.trimRight();
  return _configPrompts.any((r) => r.hasMatch(l));
}

/// Whether [command] may run without asking: the agent calls it a read,
/// MesTerm knows it as read-only, and the prompt is not a configuration one.
CommandCheck checkAgentCommand(String command, {required String intent, required String prompt}) {
  if (intent != 'read') return const CommandCheck.change(ChangeReason.agentSaysChange);
  if (isConfigPrompt(prompt)) return const CommandCheck.change(ChangeReason.configMode);
  return classifyCommand(command);
}

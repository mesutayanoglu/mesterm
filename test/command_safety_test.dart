import 'package:mesterm/services/command_safety.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('commands that only show something are read-only', () {
    for (final c in [
      'show ip interface brief',
      'sh run | include hostname',
      'show running-config | section interface',
      'display interface brief',
      'dis cur | inc sysname',
      'get system status',
      'show system info | match serial',
      'ping 192.0.2.1',
      'traceroute 198.51.100.7',
      'terminal length 0',
      'set cli pager off',
      'screen-length 0 temporary',
      'ls -la /etc',
      'cat /etc/os-release',
      'ip -br a',
      'ip route show',
      'systemctl status nginx',
      'journalctl -u nginx --since today',
      'df -h',
      'ipconfig /all',
    ]) {
      expect(classifyCommand(c).readOnly, isTrue, reason: c);
    }
  });

  test('anything that changes something, or is not known, is not', () {
    for (final c in [
      'reload',
      'write memory',
      'copy running-config startup-config',
      'configure terminal',
      'conf t',
      'interface Gi0/1',
      'no shutdown',
      'commit',
      'set deviceconfig system hostname X',
      'system-view',
      'config system interface',
      'rm -rf /tmp/x',
      'ip link set eth0 down',
      'ip addr add 192.0.2.5/24 dev eth0',
      'route add default gw 192.0.2.1',
      'systemctl restart nginx',
      'hostname NEWNAME',
      'date -s 2026-01-01',
      'dmesg -c',
      'find / -name x -delete',
      'ifconfig eth0 down',
      'ipconfig /release',
      'sudo cat /etc/shadow',
      'enable',
      'exit',
    ]) {
      expect(classifyCommand(c).readOnly, isFalse, reason: c);
    }
  });

  test('chaining, redirects and pipes into anything but a filter are changes', () {
    for (final c in [
      'show run; reload',
      'cat a && rm a',
      'cat a > b',
      'echo x >> /etc/hosts',
      'ls `rm x`',
      r'ls $(rm x)',
      'cat x | sh',
      'show run | tee flash:x',
      'ls || reboot',
    ]) {
      expect(classifyCommand(c).reason, ChangeReason.chained, reason: c);
    }
  });

  test('configuration prompts are recognised; ordinary prompts are not', () {
    for (final p in [
      'SW-01(config)#',
      'SW-01(config-if)# ',
      'FGT (interface) #',
      '[HUAWEI]',
      '[~HUAWEI-GigabitEthernet0/0/1]',
      'admin@PA-VM#',
      'user@router#',
      '[edit interfaces]',
    ]) {
      expect(isConfigPrompt(p), isTrue, reason: p);
    }
    for (final p in [
      'SW-01#',
      'SW-01>',
      '<HUAWEI>',
      'admin@PA-VM>',
      'user@host:~\$',
      'root@host:~#',
      '[user@host ~]\$',
      'FGT #',
    ]) {
      expect(isConfigPrompt(p), isFalse, reason: p);
    }
  });

  test('both sides must call it a read', () {
    expect(checkAgentCommand('show version', intent: 'read', prompt: 'SW#').readOnly, isTrue);
    expect(checkAgentCommand('show version', intent: 'change', prompt: 'SW#').reason, ChangeReason.agentSaysChange);
    expect(checkAgentCommand('reload', intent: 'read', prompt: 'SW#').reason, ChangeReason.unknown);
    expect(checkAgentCommand('show version', intent: 'read', prompt: 'SW(config)#').reason, ChangeReason.configMode);
  });
}

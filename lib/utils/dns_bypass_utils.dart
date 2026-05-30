import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class DnsBypassUtils {
  static final Map<String, String> _ipCache = {};
  static final Set<String> _failedIps = {};

  /// Marks an IP address as failed, removing it from cache so that a different one is resolved.
  static void reportFailedIp(String host, String ip) {
    debugPrint('DNS Bypass: Reporting failed IP $ip for host $host');
    _failedIps.add(ip);
    if (_ipCache[host] == ip) {
      _ipCache.remove(host);
    }
  }

  /// Resolves the hostname using custom DNS-over-HTTPS fallback if standard resolution fails.
  /// Strictly resolves to IPv4 addresses to prevent unreachable network errors on IPv6.
  static Future<String?> resolveHostname(String host) async {
    // Return cached IP if already resolved and not marked as failed
    if (_ipCache.containsKey(host)) {
      final cachedIp = _ipCache[host];
      // Verify cached IP is a valid IPv4 address (clearing stale/old IPv6 from hot-reloads)
      if (cachedIp != null && _isValidIp(cachedIp) && !_failedIps.contains(cachedIp)) {
        return cachedIp;
      }
      _ipCache.remove(host);
    }

    // Try standard DNS resolution first
    try {
      final addresses = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 4));
      if (addresses.isNotEmpty) {
        // Look for IPv4 only, filtering out failed IPs
        final ipv4 = addresses
            .where((addr) => addr.type == InternetAddressType.IPv4)
            .map((addr) => addr.address)
            .where((ip) => !_failedIps.contains(ip));
        if (ipv4.isNotEmpty) {
          final ip = ipv4.first;
          _ipCache[host] = ip;
          return ip;
        }
      }
    } catch (e) {
      debugPrint('DNS standard lookup failed for $host: $e. Trying DoH fallback...');
    }

    // Fallback to DNS-over-HTTPS using Cloudflare & Google (explicitly requesting IPv4 records)
    final ip = await _resolveViaDoH(host);
    if (ip != null && _isValidIp(ip)) {
      _ipCache[host] = ip;
      return ip;
    }

    // Do NOT return IPv6 addresses. Return null to skip DNS Bypass and fallback to default name resolution.
    debugPrint('DNS Bypass: No IPv4 found for $host. Skipping bypass.');
    return null;
  }

  static Future<String?> _resolveViaDoH(String host) async {
    // Try Cloudflare DoH first
    try {
      final url = Uri.parse('https://cloudflare-dns.com/dns-query?name=$host&type=A');
      final res = await http.get(url, headers: {
        'Accept': 'application/dns-json',
      }).timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final answers = data['Answer'] as List?;
        if (answers != null && answers.isNotEmpty) {
          for (final answer in answers) {
            if (answer['type'] == 1) { // A record
              final ip = answer['data'] as String?;
              if (ip != null && _isValidIp(ip) && !_failedIps.contains(ip)) {
                debugPrint('DoH Cloudflare resolved $host -> $ip');
                return ip;
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('DoH Cloudflare failed for $host: $e');
    }

    // Try Google DoH as backup
    try {
      final url = Uri.parse('https://dns.google/resolve?name=$host&type=A');
      final res = await http.get(url).timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final answers = data['Answer'] as List?;
        if (answers != null && answers.isNotEmpty) {
          for (final answer in answers) {
            if (answer['type'] == 1) { // A record
              final ip = answer['data'] as String?;
              if (ip != null && _isValidIp(ip) && !_failedIps.contains(ip)) {
                debugPrint('DoH Google resolved $host -> $ip');
                return ip;
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('DoH Google failed for $host: $e');
    }

    return null;
  }

  static bool _isValidIp(String ip) {
    try {
      final addr = InternetAddress.tryParse(ip);
      return addr != null && addr.type == InternetAddressType.IPv4;
    } catch (_) {
      return false;
    }
  }

  /// Rewrites the URL to use IP address directly if it was resolved via bypass.
  /// Also returns the headers map with the necessary Host header set.
  static Future<({Uri uri, Map<String, String> headers})> bypassUrl(
    String urlStr,
    Map<String, String> originalHeaders,
  ) async {
    final uri = Uri.tryParse(urlStr);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
      return (uri: Uri.parse(urlStr), headers: originalHeaders);
    }

    // Skip IP addresses
    if (_isValidIp(uri.host)) {
      return (uri: uri, headers: originalHeaders);
    }

    // Skip DoH endpoints themselves to avoid circular dependencies
    if (uri.host.contains('cloudflare-dns.com') || uri.host.contains('dns.google')) {
      return (uri: uri, headers: originalHeaders);
    }

    final ip = await resolveHostname(uri.host);
    if (ip == null || ip == uri.host) {
      return (uri: uri, headers: originalHeaders);
    }

    // Rewrite URI to use IP address
    final newHeaders = Map<String, String>.from(originalHeaders);
    newHeaders['Host'] = uri.host;

    // Preserve port if present
    final authority = uri.hasPort ? '$ip:${uri.port}' : ip;
    final newUri = uri.replace(host: ip);

    debugPrint('DNS Bypass Applied: ${uri.host} -> $authority (Original Host header set)');
    return (uri: newUri, headers: newHeaders);
  }
}

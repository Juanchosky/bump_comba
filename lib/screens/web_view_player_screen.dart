import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../utils/normalization_utils.dart';


class WebViewPlayerScreen extends StatefulWidget {
  final String url;
  final String title;

  const WebViewPlayerScreen({
    super.key,
    required this.url,
    required this.title,
  });

  @override
  State<WebViewPlayerScreen> createState() => _WebViewPlayerScreenState();
}

class _WebViewPlayerScreenState extends State<WebViewPlayerScreen> {
  bool _isLoading = true;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    // Enable wakelock to prevent screen dimming during playback
    WakelockPlus.enable();

    // Set sticky immersive mode for full-screen video
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // Restore orientation if needed
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cleanedUrl = NormalizationUtils.cleanUrl(widget.url);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(cleanedUrl)),
            initialSettings: InAppWebViewSettings(

              userAgent:
                  'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36',
              javaScriptEnabled: true,
              allowsInlineMediaPlayback: true,
              mediaPlaybackRequiresUserGesture: false,
              useShouldOverrideUrlLoading: true,
              allowsBackForwardNavigationGestures: true,
            ),
            onWebViewCreated: (controller) {
              // Web view initialized
            },
            onProgressChanged: (controller, progress) {
              setState(() {
                _progress = progress / 100;
              });
            },
            onLoadStop: (controller, url) async {
              setState(() {
                _isLoading = false;
              });

              // More aggressive Ad-blocking and UI Cleanup script
              await controller.evaluateJavascript(
                source: """
                (function() {
                  function cleanup() {
                    const selectors = [
                      'iframe[id*="goog"], iframe[src*="doubleclick"]',
                      '.header', '.footer', '.sidebar', '.top-nav', '.bottom-nav',
                      '.ad-container', '.banner-ad', '.pop-up', '.overlay',
                      'div[id*="container-"], div[id*="outstream-"]',
                      '.disclaimer', '.adsbygoogle', 'aside',
                      '#disqus_thread', '.comment-section'
                    ];
                    selectors.forEach(s => {
                      document.querySelectorAll(s).forEach(el => {
                        el.parentNode.removeChild(el); 
                      });
                    });
                    
                    // Force Video/Iframe to be main focus
                    const players = document.querySelectorAll('video, iframe[src*="embed"], iframe[src*="vidsrc"], iframe[src*="superembed"]');
                    players.forEach(p => {
                      p.style.setProperty('width', '100vw', 'important');
                      p.style.setProperty('height', '100vh', 'important');
                      p.style.setProperty('position', 'fixed', 'important');
                      p.style.setProperty('top', '0', 'important');
                      p.style.setProperty('left', '0', 'important');
                      p.style.setProperty('z-index', '999999', 'important');
                      p.style.setProperty('background', 'black', 'important');
                    });
                    
                    // Remove body padding/margin
                    document.body.style.margin = '0';
                    document.body.style.padding = '0';
                    document.body.style.overflow = 'hidden';
                    document.body.style.backgroundColor = 'black';
                  }
                  
                  cleanup();
                  setInterval(cleanup, 2000); // Repeat to catch late ads
                })()
              """,
              );
            },
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              var uri = navigationAction.request.url!;
              // Block common ad redirect domains
              final adDomains = ['onclick', 'popunder', 'bet', 'bonus', 'ads'];
              if (adDomains.any((d) => uri.host.contains(d))) {
                return NavigationActionPolicy.CANCEL;
              }
              return NavigationActionPolicy.ALLOW;
            },
          ),

          // Back Button
          Positioned(
            top: 40,
            left: 20,
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white, size: 30),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),

          // Loading Indicator
          if (_isLoading)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: Colors.amber),
                  const SizedBox(height: 16),
                  Text(
                    'Cargando reproductor en la web...',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: 200,
                    child: LinearProgressIndicator(
                      value: _progress,
                      color: Colors.amber,
                      backgroundColor: Colors.white12,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

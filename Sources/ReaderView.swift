import SwiftUI
import UIKit
import WebKit

// MARK: - SwiftUI 包装

/// 让 SwiftUI 上层能命令阅读器（跳章 / 搜索 / 重绘高亮）
final class ReaderProxy {
    weak var controller: ReaderController?
    func jump(to chapter: Int, fraction: Double = 0) {
        controller?.jump(toChapter: chapter, fraction: fraction)
    }
    func search(_ q: String) { controller?.search(q) }
    func step(_ d: Int) { controller?.stepMatch(d) }
    func turn(_ d: Int) { controller?.turn(d) }
}

struct ReaderView: UIViewControllerRepresentable {
    let content: BookContent
    var settings: ReaderSettings
    var locator: ReadingLocator
    var highlights: [Highlight] = []
    var proxy: ReaderProxy?
    var onLocatorChange: (ReadingLocator) -> Void
    var onTapCenter: () -> Void
    var onSelection: ((Int, Int, String) -> Void)?
    var onMatches: ((Int) -> Void)?
    var onNoteref: ((String) -> Void)?

    func makeUIViewController(context: Context) -> ReaderController {
        let c = ReaderController(content: content,
                                 settings: settings,
                                 locator: locator)
        _ = c.view            // 先把 view 装起来，webView 才会在 viewDidLoad 里创建
        c.onLocatorChange = onLocatorChange
        c.onTapCenter = onTapCenter
        c.onSelection = onSelection
        c.onMatches = onMatches
        c.onNoteref = onNoteref
        c.applyHighlights(highlights)
        proxy?.controller = c
        return c
    }

    func updateUIViewController(_ c: ReaderController, context: Context) {
        c.apply(settings: settings)
        c.applyHighlights(highlights)
    }
}

// MARK: - 控制器

final class ReaderController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {

    private let content: BookContent
    private var settings: ReaderSettings
    private var locator: ReadingLocator
    private var chapterIndex: Int
    private var webView: WKWebView!
    private var currentFraction: Double
    private var pendingRestore: Double?

    var onLocatorChange: ((ReadingLocator) -> Void)?
    var onTapCenter: (() -> Void)?
    var onSelection: ((Int, Int, String) -> Void)?
    var onMatches: ((Int) -> Void)?
    var onNoteref: ((String) -> Void)?
    private var pendingHighlights: [Highlight] = []
    private var matches: [Int] = []
    private var matchQuery = ""
    private var matchIndex = 0

    init(content: BookContent, settings: ReaderSettings, locator: ReadingLocator) {
        self.content = content
        self.settings = settings
        self.locator = locator
        self.chapterIndex = min(max(0, locator.chapterIndex), max(0, content.chapters.count - 1))
        self.currentFraction = locator.fraction
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        CrashLog.append("reader webview viewDidLoad")
        view.backgroundColor = UIColor(hex: settings.theme.background)
        UIApplication.shared.isIdleTimerDisabled = true

        let conf = WKWebViewConfiguration()
        conf.userContentController.add(self, name: "reader")
        conf.suppressesIncrementalRendering = false

        webView = WKWebView(frame: view.bounds, configuration: conf)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        view.addSubview(webView)

        loadChapter(chapterIndex, restoreFraction: currentFraction)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        reportLocation()
    }

    // MARK: 加载

    private func bodyHTML(for chapter: Chapter) -> String {
        if let url = chapter.fileURL,
           let raw = try? String(contentsOf: url, encoding: .utf8) {
            return Self.extractBody(raw)
        }
        return chapter.html
    }

    private func loadChapter(_ index: Int, restoreFraction: Double) {
        guard content.chapters.indices.contains(index) else { return }
        guard isViewLoaded, let web = webView else { return }
        let chapter = content.chapters[index]
        let html = Self.page(body: bodyHTML(for: chapter),
                             title: chapter.title,
                             settings: settings)
        pendingRestore = restoreFraction
        web.loadHTMLString(html, baseURL: content.baseDirectory)
    }

    func apply(settings new: ReaderSettings) {
        let changed = new != settings
        settings = new
        view.backgroundColor = UIColor(hex: settings.theme.background)
        guard changed else { return }
        let js = "window.__applyStyle(\(Self.styleJSON(settings)));"
        eval(js)
    }

    // MARK: 对外 API（目录跳转 / 搜索 / 高亮）

    func jump(toChapter index: Int, fraction: Double = 0) {
        guard content.chapters.indices.contains(index) else { return }
        chapterIndex = index
        currentFraction = fraction
        loadChapter(index, restoreFraction: fraction)
        reportLocation()
    }

    func search(_ query: String) {
        guard !query.isEmpty else { return }
        matchQuery = query
        matchIndex = 0
        eval("window.__findAll(\(Self.jsString(query)));")
    }

    func stepMatch(_ delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        gotoMatch(matchIndex)
    }

    private func gotoMatch(_ i: Int) {
        guard matches.indices.contains(i) else { return }
        let off = matches[i]
        eval("window.__gotoAt(\(off), \(max(1, matchQuery.count)));")
    }

    func applyHighlights(_ list: [Highlight]) {
        pendingHighlights = list
        pushHighlights()
    }

    /// 所有 JS 注入都走这里：view 还没装好或 webView 还没建出来时直接跳过，
    /// 不要用 `webView!` —— 那会在 makeUIViewController 阶段 SIGTRAP
    private func eval(_ js: String) {
        guard isViewLoaded, let web = webView else { return }
        web.evaluateJavaScript(js, completionHandler: nil)
    }

    private func pushHighlights() {
        guard isViewLoaded, webView != nil else { return }
        let arr = pendingHighlights.map { h in
            "{\"start\":\(h.start),\"end\":\(h.end),\"c\":\"\(h.color.css)\",\"id\":\"\(h.id.uuidString)\"}"
        }.joined(separator: ",")
        eval("window.__paint && window.__paint([\(arr)]);")
    }

    private static func jsString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            default:
                if ch.value < 32 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out + "\""
    }

    // MARK: 进度

    private func reportLocation() {
        let loc = content.locator(forChapter: chapterIndex, fraction: currentFraction)
        locator = loc
        onLocatorChange?(loc)
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ ucc: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            if let f = pendingRestore {
                pendingRestore = nil
                let js = "window.__restore(\(f));"
                eval(js)
            }
        case "tap":
            let x = body["x"] as? Double ?? 0.5
            if x < 0.28 { turnPage(-1) }
            else if x > 0.72 { turnPage(1) }
            else { onTapCenter?() }
        case "progress":
            currentFraction = body["fraction"] as? Double ?? 0
            if let end = body["atEnd"] as? Bool, end == true {
                turnPage(1)
            }
        case "selection":
            let s = body["start"] as? Int ?? 0
            let e = body["end"] as? Int ?? 0
            let txt = body["text"] as? String ?? ""
            if e > s { onSelection?(s, e, txt) }
        case "matches":
            let list = body["list"] as? [Int] ?? []
            matches = list
            matchIndex = 0
            onMatches?(list.count)
            if !list.isEmpty { gotoMatch(0) }
        case "note":
            if let t = body["text"] as? String, !t.isEmpty { onNoteref?(t) }
        case "search":
            let found = body["found"] as? Int ?? 0
            if found == 0 { onSelection?(-1, -1, "") }
        default:
            break
        }
    }

    private func turnPage(_ dir: Int) {
        eval("window.__turn(\(dir));")
    }

    func turn(_ dir: Int) { turnPage(dir) }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // ready 消息会带回恢复请求；这里只兜底一次进度上报
        eval("window.__report && window.__report();")
        pushHighlights()
    }

    // MARK: HTML 模板

    private static func extractBody(_ raw: String) -> String {
        var s = raw
        if let r = s.range(of: "<body", options: .caseInsensitive) {
            if let start = s[r.lowerBound...].firstIndex(of: ">") {
                s = String(s[s.index(after: start)...])
            }
        }
        if let end = s.range(of: "</body>", options: .caseInsensitive, range: s.startIndex..<s.endIndex) {
            s = String(s[..<end.lowerBound])
        }
        return s.replacingOccurrences(of: "<script", with: "<script-disabled",
                                      options: .caseInsensitive)
    }

    private static func styleJSON(_ s: ReaderSettings) -> String {
        """
        {"fontSize":\(s.fontSize),"lineHeight":\(s.lineHeight),
         "fontFamily":"\(s.fontFamily)","indent":\(s.indentEM),
         "para":\(s.paragraphSpacingEM),"bg":"\(s.theme.background)",
         "fg":"\(s.theme.foreground)","paged":\(s.paged ? "true" : "false"),
         "kinsoku":\(s.kinsoku ? "true" : "false"),
         "autospace":\(s.autospace ? "true" : "false")}
        """
    }

    private static func page(body: String, title: String, settings s: ReaderSettings) -> String {
        """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style id="ys">
          html,body{margin:0;padding:0;background:\(s.theme.background);color:\(s.theme.foreground);
            -webkit-text-size-adjust:none;-webkit-font-smoothing:antialiased;}
          body{padding:14px 20px 28px 20px;font-family:"\(s.fontFamily)",-apple-system,serif;
            font-size:\(s.fontSize)px;line-height:\(s.lineHeight);text-align:justify;
            line-break:strict;word-break:normal;overflow-wrap:break-word;}
          p{margin:0 0 \(s.paragraphSpacingEM)em 0;text-indent:\(s.indentEM)em;}
          p:last-child{margin-bottom:0;}
          h1,h2,h3{line-height:1.45;margin:1.1em 0 .6em;text-indent:0;font-weight:600;}
          img{max-width:100%;height:auto;display:block;margin:1em auto;}
          a{color:inherit;text-decoration:underline dotted;}
          blockquote{margin:1em 0;padding-left:1em;border-left:3px solid rgba(128,128,128,.35);}
          ruby rt{font-size:.5em;}
          .y-paged body{column-width:100vw;column-gap:0;height:100vh;overflow:hidden;}
        </style>
        </head><body><div id="yc">\(body)</div>
        <script>\(script(s))</script>
        </body></html>
        """
    }

    private static func script(_ s: ReaderSettings) -> String {
        """
        (function(){
          var post=function(o){try{window.webkit.messageHandlers.reader.postMessage(o)}catch(e){}};
          var paged=\(s.paged ? "true" : "false");
          document.body.classList.toggle('y-paged', paged);

          function content(){return document.getElementById('yc')}
          function frac(){
            if(paged){var el=document.scrollingElement||document.documentElement;
              var w=el.scrollWidth-el.clientWidth;
              return w<=0?0:el.scrollLeft/w;}
            var el=document.scrollingElement||document.documentElement;
            var h=el.scrollHeight-el.clientHeight;
            return h<=0?0:el.scrollTop/h;
          }
          function report(){
            var f=frac();
            post({type:'progress',fraction:f,atEnd:f>0.999});
          }
          window.__report=report;

          window.__restore=function(f){
            if(!f){return}
            if(paged){var el=document.scrollingElement;el.scrollLeft=(el.scrollWidth-el.clientWidth)*f;}
            else{var el=document.scrollingElement;el.scrollTop=(el.scrollHeight-el.clientHeight)*f;}
          };

          window.__turn=function(dir){
            if(paged){window.scrollBy({left:dir*window.innerWidth,behavior:'smooth'});}
            else{window.scrollBy({top:dir*(window.innerHeight*0.9),behavior:'smooth'});}
          };

          window.__applyStyle=function(cfg){
            document.body.style.background=cfg.bg;
            document.body.style.color=cfg.fg;
            document.body.style.fontSize=cfg.fontSize+'px';
            document.body.style.lineHeight=cfg.lineHeight;
            document.body.style.fontFamily='"'+cfg.fontFamily+'",-apple-system,serif';
            document.body.classList.toggle('y-paged', !!cfg.paged);
            paged=!!cfg.paged;
            var ps=content().querySelectorAll('p');
            for(var i=0;i<ps.length;i++){
              ps[i].style.textIndent=cfg.indent+'em';
              ps[i].style.marginBottom=cfg.para+'em';
            }
          };

          // 点击分区
          document.addEventListener('click',function(e){
            var t=e.target;
            var a=t&&t.closest?t.closest('a'):null;
            if(a){
              var href=a.getAttribute('href')||'';
              if(href.charAt(0)==='#'){
                e.preventDefault();
                var el=document.getElementById(href.slice(1));
                var txt=el?(el.innerText||el.textContent||''):(a.textContent||'');
                post({type:'note',text:txt.slice(0,800)});
              }
              return;
            }
            post({type:'tap',x:e.clientX/window.innerWidth,y:e.clientY/window.innerHeight});
          },true);

          var t=null;
          window.addEventListener('scroll',function(){
            if(t){clearTimeout(t)}
            t=setTimeout(report,180);
          },{passive:true});

          // 中文中西文混排间距（粗粒度）
          if(\(s.autospace ? "true" : "false")){
            var c=content();
            var walker=document.createTreeWalker(c,NodeFilter.SHOW_TEXT,null);
            var n;
            while((n=walker.nextNode())){
              if(n.parentNode&&n.parentNode.tagName==='SCRIPT'){continue}
              n.nodeValue=n.nodeValue
                .replace(/([\\u4e00-\\u9fa5])([A-Za-z0-9])/g,'$1\\u2009$2')
                .replace(/([A-Za-z0-9])([\\u4e00-\\u9fa5])/g,'$1\\u2009$2');
            }
          }

          function textNodes(){
            var out=[],w=document.createTreeWalker(content(),NodeFilter.SHOW_TEXT,null),n;
            while((n=w.nextNode())){out.push(n)}
            return out;
          }
          function wrapRange(nodes,s,e,col,id){
            var pos=0;
            for(var i=0;i<nodes.length;i++){
              var n=nodes[i],len=n.nodeValue?n.nodeValue.length:0,ns=pos,ne=pos+len;
              pos=ne;
              if(ne<=s||ns>=e){continue}
              var a=Math.max(s,ns)-ns,b=Math.min(e,ne)-ns;
              if(b<=a){continue}
              var r=document.createRange();r.setStart(n,a);r.setEnd(n,b);
              var m=document.createElement('mark');
              m.className='yh';m.setAttribute('data-hid',id);
              m.style.background=col;m.style.color='inherit';m.style.padding='0';
              try{r.surroundContents(m)}catch(err){}
            }
          }
          window.__paint=function(list){
            var ms=content().querySelectorAll('mark.yh');
            for(var i=0;i<ms.length;i++){
              var m=ms[i],p=m.parentNode;
              while(m.firstChild){p.insertBefore(m.firstChild,m)}
              p.removeChild(m);
            }
            content().normalize();
            if(!list||!list.length){return}
            for(var k=0;k<list.length;k++){
              var h=list[k];
              wrapRange(textNodes(),h.start,h.end,h.c,h.id);
              content().normalize();
            }
          };
          function offsetOf(node){
            var w=document.createTreeWalker(content(),NodeFilter.SHOW_TEXT,null),n,pos=0;
            while((n=w.nextNode())){
              if(n===node){return pos}
              pos+=n.nodeValue.length;
            }
            return -1;
          }
          function reportSelection(){
            var sel=window.getSelection();
            if(!sel||sel.isCollapsed||!sel.rangeCount){return}
            var r=sel.getRangeAt(0);
            var a=offsetOf(r.startContainer),b=offsetOf(r.endContainer);
            if(a<0||b<0){return}
            a+=r.startOffset;b+=r.endOffset;
            if(b<=a){return}
            post({type:'selection',start:a,end:b,text:sel.toString().slice(0,400)});
          }
          function plainText(){
            var nodes=textNodes(),all='';
            for(var i=0;i<nodes.length;i++){all+=(nodes[i].nodeValue||'')}
            return all;
          }
          window.__findAll=function(q){
            if(!q){return}
            var all=plainText(),idx=all.indexOf(q),list=[];
            while(idx>=0&&list.length<300){list.push(idx);idx=all.indexOf(q,idx+q.length)}
            post({type:'matches',q:q,list:list});
          };
          window.__gotoAt=function(off,len){
            var nodes=textNodes(),pos=0;
            for(var j=0;j<nodes.length;j++){
              var l=nodes[j].nodeValue?nodes[j].nodeValue.length:0;
              if(pos+l>off){
                var rg=document.createRange();
                rg.setStart(nodes[j],off-pos);
                rg.setEnd(nodes[j],Math.min(l,off-pos+len));
                var rc=rg.getBoundingClientRect();
                window.scrollBy({top:rc.top-window.innerHeight*0.3,behavior:'smooth'});
                return;
              }
              pos+=l;
            }
          };
          document.addEventListener('selectionchange',function(){
            if(window.__st){clearTimeout(window.__st)}
            window.__st=setTimeout(reportSelection,320);
          });

          post({type:'ready'});
          setTimeout(report,120);
        })();
        """
    }
}

// MARK: - 颜色

extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = CGFloat((v & 0xFF0000) >> 16) / 255
        let g = CGFloat((v & 0x00FF00) >> 8) / 255
        let b = CGFloat(v & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

import SwiftUI
import WebKit

/// 容器 → 阅读器 的单向调用通道（SwiftUI 每次重建 struct 也不会丢 controller）
final class ReaderProxy {
    weak var controller: ReaderController?

    func jump(to index: Int, fraction: Double = 0) {
        controller?.jump(toChapter: index, fraction: fraction)
    }
    /// 跳到某章某个字符位置（笔记回跳用）
    func jumpChar(_ index: Int, offset: Int) {
        controller?.jumpChar(index, offset: offset)
    }
    func search(_ q: String) { controller?.search(q) }
    func step(_ d: Int) { controller?.stepMatch(d) }
    func turn(_ d: Int) { controller?.turn(d) }
    func repaint(_ list: [Highlight]) { controller?.applyHighlights(list) }
    var pageInfo: (Int, Int) { controller?.pageInfo ?? (0, 1) }
}

struct ReaderView: UIViewControllerRepresentable {
    let content: BookContent
    var settings: ReaderSettings
    var locator: ReadingLocator
    var highlights: [Highlight]
    var proxy: ReaderProxy?

    var onLocatorChange: ((ReadingLocator) -> Void)?
    var onTapCenter: (() -> Void)?
    var onSelection: ((Int, Int, String) -> Void)?
    var onMatches: ((Int) -> Void)?
    var onPage: ((Int, Int) -> Void)?
    var onNoteref: ((String) -> Void)?

    func makeUIViewController(context: Context) -> ReaderController {
        let c = ReaderController(content: content, settings: settings, locator: locator)
        c.onLocatorChange = onLocatorChange
        c.onTapCenter = onTapCenter
        c.onSelection = onSelection
        c.onMatches = onMatches
        c.onPage = onPage
        c.onNoteref = onNoteref
        proxy?.controller = c
        _ = c.view                    // 立刻把 view 装起来，webView 随之创建
        c.applyHighlights(highlights)
        return c
    }

    func updateUIViewController(_ c: ReaderController, context: Context) {
        c.updateSettings(settings)
        c.applyHighlights(highlights)
    }
}

// MARK: - 阅读器

final class ReaderController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, UIGestureRecognizerDelegate {

    private let content: BookContent
    private var settings: ReaderSettings
    private var chapterIndex: Int
    private var currentFraction: Double = 0
    private var page = 0, total = 1

    private var webView: WKWebView!
    private var pendingRestore: Double?
    private var pendingHighlights: [Highlight] = []
    private var pushedHighlights: [Highlight] = []
    private var pushedSettings: ReaderSettings?
    private var loadedChapter: Int = -1

    private var matches: [Int] = []
    private var matchQuery = ""
    private var matchIndex = 0

    var onLocatorChange: ((ReadingLocator) -> Void)?
    var onTapCenter: (() -> Void)?
    var onSelection: ((Int, Int, String) -> Void)?
    var onMatches: ((Int) -> Void)?
    var onPage: ((Int, Int) -> Void)?
    var onNoteref: ((String) -> Void)?

    var pageInfo: (Int, Int) { (page, total) }

    init(content: BookContent, settings: ReaderSettings, locator: ReadingLocator) {
        self.content = content
        self.settings = settings
        self.chapterIndex = max(0, min(locator.chapterIndex, max(0, content.chapters.count - 1)))
        self.currentFraction = locator.fraction
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 视图

    override func loadView() {
        let conf = WKWebViewConfiguration()
        conf.allowsInlineMediaPlayback = true
        conf.userContentController.add(self, name: "reader")

        let web = WKWebView(frame: UIScreen.main.bounds, configuration: conf)
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.bounces = false
        web.scrollView.alwaysBounceVertical = false
        web.scrollView.alwaysBounceHorizontal = false
        web.scrollView.showsVerticalScrollIndicator = false
        web.scrollView.showsHorizontalScrollIndicator = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        self.webView = web
        self.view = web
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        CrashLog.append("reader webview viewDidLoad chapters=\(content.chapters.count) ch=\(chapterIndex)")
        loadChapter(chapterIndex, restoreFraction: currentFraction)

        let left = UISwipeGestureRecognizer(target: self, action: #selector(swipeLeft))
        left.direction = .left
        let right = UISwipeGestureRecognizer(target: self, action: #selector(swipeRight))
        right.direction = .right
        for g in [left, right] {
            g.delegate = self
            webView.addGestureRecognizer(g)
        }
    }

    @objc private func swipeLeft() { turn(1) }
    @objc private func swipeRight() { turn(-1) }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: 章节装载

    private func bodyHTML(for chapter: Chapter) -> String {
        if let url = chapter.fileURL,
           let raw = try? String(contentsOf: url, encoding: .utf8) {
            return Self.extractBody(raw)
        }
        return chapter.html
    }

    private func loadChapter(_ index: Int, restoreFraction: Double) {
        guard content.chapters.indices.contains(index) else { return }
        guard webView != nil else { return }
        chapterIndex = index
        loadedChapter = index
        let chapter = content.chapters[index]
        pendingRestore = restoreFraction
        let html = Self.page(body: bodyHTML(for: chapter),
                             settings: settings)
        page = 0
        webView.loadHTMLString(html, baseURL: content.baseDirectory)
    }

    func jump(toChapter index: Int, fraction: Double) {
        guard content.chapters.indices.contains(index) else { return }
        if index == loadedChapter {
            eval("window.__restore(\(fraction));")
        } else {
            loadChapter(index, restoreFraction: fraction)
        }
        reportLocation()
    }

    func jumpChar(_ index: Int, offset: Int) {
        guard content.chapters.indices.contains(index) else { return }
        let same = index == loadedChapter
        jump(toChapter: index, fraction: 0)
        let delay = same ? 0.12 : 0.8
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.eval("window.__gotoAt(\(offset), 1);")
        }
    }

    // MARK: 设置

    func updateSettings(_ new: ReaderSettings) {
        let changed = new != settings
        settings = new
        if changed || pushedSettings == nil {
            pushedSettings = new
            eval("window.__applyStyle(\(Self.styleJSON(new)));")
        }
    }

    // MARK: 高亮

    func applyHighlights(_ list: [Highlight]) {
        pendingHighlights = list
        if list.map({ $0.id }) == pushedHighlights.map({ $0.id })
            && list.map({ $0.color }) == pushedHighlights.map({ $0.color }) {
            return
        }
        pushedHighlights = list
        pushHighlights()
    }

    private func pushHighlights() {
        guard webView != nil else { return }
        let arr = pendingHighlights.map { h in
            "{\"start\":\(h.start),\"end\":\(h.end),\"c\":\"\(h.color.css)\",\"id\":\"\(h.id.uuidString)\"}"
        }.joined(separator: ",")
        eval("window.__paint([\(arr)]);")
    }

    // MARK: 搜索

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
        eval("window.__gotoAt(\(matches[i]), \(matchQuery.count));")
    }

    // MARK: 翻页

    func turn(_ dir: Int) {
        if settings.paged {
            eval("window.__pageBy(\(dir));")
        } else {
            eval("window.__scrollBy(\(dir));")
        }
    }

    // MARK: 唯一的 JS 入口

    private func eval(_ js: String) {
        guard isViewLoaded, let web = webView else { return }
        web.evaluateJavaScript(js, completionHandler: nil)
    }

    private func reportLocation() {
        let loc = content.locator(forChapter: chapterIndex, fraction: currentFraction)
        onLocatorChange?(loc)
    }

    // MARK: 消息

    func userContentController(_ ucc: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            if let f = pendingRestore {
                pendingRestore = nil
                eval("window.__restore(\(f));")
            }
            pushHighlights()
            eval("window.__applyStyle(\(Self.styleJSON(settings)));")

        case "page":
            page = body["page"] as? Int ?? 0
            total = max(1, body["total"] as? Int ?? 1)
            currentFraction = total > 1 ? Double(page) / Double(total - 1) : 0
            onPage?(page + 1, total)
            reportLocation()

        case "progress":
            currentFraction = body["fraction"] as? Double ?? 0
            reportLocation()

        case "tap":
            let x = body["x"] as? Double ?? 0.5
            if x < 0.26 { turn(-1) }
            else if x > 0.74 { turn(1) }
            else { onTapCenter?() }

        case "selection":
            let s = body["start"] as? Int ?? -1
            let e = body["end"] as? Int ?? -1
            let txt = body["text"] as? String ?? ""
            if s >= 0, e > s, !txt.isEmpty { onSelection?(s, e, txt) }

        case "matches":
            let list = body["list"] as? [Int] ?? []
            matches = list
            matchIndex = 0
            onMatches?(list.count)
            if !list.isEmpty { gotoMatch(0) }

        case "log":
            if let m = body["msg"] as? String { CrashLog.append("js: \(m)") }

        case "note":
            if let t = body["text"] as? String, !t.isEmpty { onNoteref?(t) }

        default:
            break
        }
    }

    // MARK: 导航

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        eval("window.__applyStyle(\(Self.styleJSON(settings)));")
        pushHighlights()
    }

    // MARK: 工具

    private static func jsString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
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

    private static func styleJSON(_ s: ReaderSettings) -> String {
        let paged = s.paged ? "true" : "false"
        let kinsoku = s.kinsoku ? "true" : "false"
        let autospace = s.autospace ? "true" : "false"
        return "{\"fontSize\":\(s.fontSize),\"lineHeight\":\(s.lineHeight),\"fontFamily\":\"\(s.fontFamily)\",\"indent\":\(s.indentEM),\"para\":\(s.paragraphSpacingEM),\"bg\":\"\(s.theme.background)\",\"fg\":\"\(s.theme.foreground)\",\"paged\":\(paged),\"kinsoku\":\(kinsoku),\"autospace\":\(autospace)}"
    }

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
        s = s.replacingOccurrences(of: "<script", with: "<script-off", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<iframe", with: "<iframe-off", options: .caseInsensitive)
        return s
    }

    // MARK: 页面模板

    private static func page(body: String, settings s: ReaderSettings) -> String {
        let css = """
        html,body{margin:0;padding:0;height:100%;width:100%;overflow:hidden;
          background:\(s.theme.background);color:\(s.theme.foreground);
          -webkit-text-size-adjust:none;-webkit-font-smoothing:antialiased;}
        #wrap{position:relative;width:100vw;height:100vh;overflow:hidden;scroll-behavior:smooth;}
        #yc{box-sizing:border-box;width:100vw;height:100vh;padding:16px 20px 34px 20px;
          -webkit-column-width:100vw;-moz-column-width:100vw;column-width:100vw;
          -webkit-column-gap:0;column-gap:0;
          -webkit-column-fill:auto;column-fill:auto;
          font-family:"\(s.fontFamily)",-apple-system,serif;font-size:\(s.fontSize)px;
          line-height:\(s.lineHeight);text-align:justify;line-break:strict;
          word-break:normal;overflow-wrap:break-word;}
        .y-scroll #wrap{overflow-y:auto;overflow-x:hidden;scroll-behavior:auto;-webkit-overflow-scrolling:touch;}
        .y-scroll #yc{height:auto;width:100%;column-width:auto;-webkit-column-width:auto;padding-bottom:64px;}
        p{margin:0 0 \(s.paragraphSpacingEM)em 0;text-indent:\(s.indentEM)em;}
        p:last-child{margin-bottom:0;}
        h1,h2,h3{line-height:1.45;margin:1.1em 0 .6em;text-indent:0;font-weight:600;}
        img{max-width:100%;height:auto;display:block;margin:1em auto;}
        a{color:inherit;text-decoration:underline dotted;}
        blockquote{margin:1em 0;padding-left:1em;border-left:3px solid rgba(128,128,128,.35);}
        ruby rt{font-size:.5em;}
        mark.yh{padding:0;color:inherit;border-radius:2px;}
        """

        return """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>\(css)</style>
        </head>
        <body><div id="wrap"><div id="yc">\(body)</div></div>
        <script>\(script(s))</script>
        </body></html>
        """
    }

    private static func script(_ s: ReaderSettings) -> String {
        let paged = s.paged ? "true" : "false"
        let autospace = s.autospace ? "true" : "false"

        return #"""
        (function(){
          var root=document.documentElement;
          var wrap=document.getElementById('wrap');
          var yc=document.getElementById('yc');
          var page=0,total=1,paged=__PAGED__,busy=false;

          function post(o){try{window.webkit.messageHandlers.reader.postMessage(o)}catch(e){}}
          function log(m){post({type:'log',msg:String(m)})}
          function W(){return wrap.clientWidth||window.innerWidth}
          function H(){return wrap.clientHeight||window.innerHeight}

          function applyMode(){
            root.classList.toggle('y-scroll',!paged);
          }

          function measure(){
            if(!paged){ total=1; return }
            var sw=Math.max(yc.scrollWidth,wrap.scrollWidth);
            total=Math.max(1,Math.ceil((sw-2)/W()));
          }

          function tell(){
            if(paged){ post({type:'page',page:page,total:total}) }
            else{
              var max=wrap.scrollHeight-wrap.clientHeight;
              post({type:'progress',fraction:max<=0?0:wrap.scrollTop/max});
            }
          }

          function go(n,animate){
            measure();
            page=Math.max(0,Math.min(total-1,Math.round(n)));
            busy=true;
            try{
              wrap.scrollTo({left:page*W(),top:0,behavior:animate===false?'auto':'smooth'});
            }catch(e){ wrap.scrollLeft=page*W() }
            setTimeout(function(){ busy=false; tell() },animate===false?30:340);
            tell();
          }

          window.__pageBy=function(d){ go(page+d) };
          window.__goPage=function(n){ go(n) };
          window.__pageInfo=function(){ measure(); return {page:page,total:total} };

          window.__restore=function(f){
            f=Number(f)||0;
            measure();
            if(paged){ go(Math.round(f*(total-1)),false) }
            else{
              var max=wrap.scrollHeight-wrap.clientHeight;
              wrap.scrollTop=max*f; tell();
            }
          };

          window.__scrollBy=function(d){
            if(paged){ go(page+d) }
            else{ wrap.scrollBy({top:d*H()*0.86,behavior:'smooth'}) }
          };

          window.__applyStyle=function(cfg){
            document.body.style.background=cfg.bg;
            document.body.style.color=cfg.fg;
            yc.style.fontSize=cfg.fontSize+'px';
            yc.style.lineHeight=cfg.lineHeight;
            yc.style.fontFamily='"'+cfg.fontFamily+'",-apple-system,serif';
            var ps=yc.querySelectorAll('p');
            for(var i=0;i<ps.length;i++){
              ps[i].style.textIndent=cfg.indent+'em';
              ps[i].style.marginBottom=cfg.para+'em';
            }
            var want=!!cfg.paged;
            if(want!==paged){ paged=want; applyMode(); page=0; wrap.scrollLeft=0; wrap.scrollTop=0 }
            applyMode();
            measure();
            if(paged&&total<=1&&yc.scrollHeight>H()*1.2){
              log('columns-failed h='+yc.scrollHeight+' w='+W());
              paged=false; applyMode(); page=0;
            }
            go(page,false);
          };

          function textNodes(){
            var out=[],w=document.createTreeWalker(yc,NodeFilter.SHOW_TEXT,null),n;
            while((n=w.nextNode())){ out.push(n) }
            return out;
          }
          function charOffsetOf(node,off){
            var nodes=textNodes(),pos=0;
            for(var i=0;i<nodes.length;i++){
              if(nodes[i]===node){ return pos+off }
              pos+=(nodes[i].nodeValue?nodes[i].nodeValue.length:0);
            }
            return -1;
          }
          function rectOf(off,len){
            var nodes=textNodes(),pos=0;
            for(var i=0;i<nodes.length;i++){
              var t=nodes[i],l=t.nodeValue?t.nodeValue.length:0;
              if(pos+l>off){
                var a=Math.max(0,off-pos), b=Math.min(l,a+Math.max(1,len));
                try{
                  var r=document.createRange();
                  r.setStart(t,a); r.setEnd(t,b);
                  return r.getBoundingClientRect();
                }catch(e){ return null }
              }
              pos+=l;
            }
            return null;
          }

          window.__gotoAt=function(off,len){
            var rc=rectOf(off,len||1);
            if(!rc){ return }
            if(paged){
              var left=rc.left+wrap.scrollLeft;
              go(Math.floor((left+W()*0.03)/W()));
            }else{
              var cur=wrap.getBoundingClientRect().top;
              wrap.scrollBy({top:(rc.top-cur)-H()*0.3,behavior:'smooth'});
            }
          };

          function wrapRange(nodes,s,e,col,id){
            var pos=0;
            for(var i=0;i<nodes.length;i++){
              var n=nodes[i],len=n.nodeValue?n.nodeValue.length:0,ns=pos,ne=pos+len;
              pos=ne;
              if(ne<=s||ns>=e){ continue }
              var a=Math.max(s,ns)-ns,b=Math.min(e,ne)-ns;
              if(b<=a){ continue }
              var r=document.createRange();
              r.setStart(n,a); r.setEnd(n,b);
              var m=document.createElement('mark');
              m.className='yh';
              m.setAttribute('data-hid',id);
              m.style.background=col;
              m.style.color='inherit';
              try{ r.surroundContents(m) }catch(err){}
            }
          }

          window.__paint=function(list){
            var ms=yc.querySelectorAll('mark.yh');
            for(var i=ms.length-1;i>=0;i--){
              var m=ms[i],p=m.parentNode;
              if(!p){ continue }
              while(m.firstChild){ p.insertBefore(m.firstChild,m) }
              p.removeChild(m);
            }
            yc.normalize();
            if(list&&list.length){
              for(var k=0;k<list.length;k++){
                var h=list[k];
                wrapRange(textNodes(),h.start,h.end,h.c,h.id);
              }
              yc.normalize();
            }
            go(page,false);
          };

          function reportSelection(){
            var sel=window.getSelection();
            if(!sel||sel.isCollapsed||!sel.rangeCount){ return }
            var t=String(sel).replace(/\s+$/,'');
            if(!t){ return }
            var r=sel.getRangeAt(0);
            var a=charOffsetOf(r.startContainer,r.startOffset);
            var b=charOffsetOf(r.endContainer,r.endOffset);
            if(a<0||b<=a){ return }
            post({type:'selection',start:a,end:b,text:t.slice(0,400)});
          }
          window.__sel=reportSelection;

          window.__findAll=function(q){
            if(!q){ post({type:'matches',q:q,list:[]}); return }
            var all='',nodes=textNodes();
            for(var i=0;i<nodes.length;i++){ all+=(nodes[i].nodeValue||'') }
            var idx=all.indexOf(q),list=[];
            while(idx>=0&&list.length<400){ list.push(idx); idx=all.indexOf(q,idx+q.length) }
            post({type:'matches',q:q,list:list});
          };

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
            post({type:'tap',x:e.clientX/W(),y:e.clientY/H()});
          },true);

          var sx=0,sy=0,st=0,armed=false;
          wrap.addEventListener('touchstart',function(e){
            if(e.touches.length!==1){ armed=false; return }
            var t=e.touches[0]; sx=t.clientX; sy=t.clientY; st=Date.now(); armed=true;
          },{passive:true});
          wrap.addEventListener('touchend',function(e){
            if(!armed){ return }
            armed=false;
            var sel=window.getSelection();
            if(sel&&!sel.isCollapsed){ setTimeout(reportSelection,40); return }
            var t=e.changedTouches[0];
            var dx=t.clientX-sx, dy=t.clientY-sy, dt=Date.now()-st;
            if(Math.abs(dx)>44&&Math.abs(dx)>Math.abs(dy)*1.3&&dt<900){
              go(page+(dx<0?1:-1));
            }
          },{passive:true});

          wrap.addEventListener('scroll',function(){
            if(busy){ return }
            if(paged){
              var p=Math.round(wrap.scrollLeft/W());
              if(p!==page){ page=p; tell() }
            }else{
              if(!window.__t){ window.__t=setTimeout(function(){ window.__t=null; tell() },160) }
            }
          },{passive:true});

          if(__AUTOSPACE__){
            var tn=textNodes();
            for(var j=0;j<tn.length;j++){
              var node=tn[j];
              if(node.parentNode&&node.parentNode.tagName==='SCRIPT'){ continue }
              node.nodeValue=node.nodeValue
                .replace(/([\u4e00-\u9fa5])([A-Za-z0-9])/g,'$1\u2009$2')
                .replace(/([A-Za-z0-9])([\u4e00-\u9fa5])/g,'$1\u2009$2');
            }
          }

          applyMode();
          measure();
          go(0,false);
          var chars=(yc.textContent||'').length;
          log('ready chars='+chars+' total='+total+' paged='+paged+' sw='+yc.scrollWidth+' w='+W());
          post({type:'ready'});
          setTimeout(tell,80);
        })();
        """#
        .replacingOccurrences(of: "__PAGED__", with: paged)
        .replacingOccurrences(of: "__AUTOSPACE__", with: autospace)
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

import AppKit
import AVFoundation

/// Scenen som delas i mötesappen: källans bild, dimning/spotlight och kamerabubblan.
/// Lagerkoordinaterna är oflippade (origo nere till vänster); inställningarna använder
/// normaliserade koordinater med origo uppe till vänster och översätts här.
@MainActor
final class StageView: NSView {
    weak var controller: AppController?
    /// Förhandsvisningen i inställningarna: musen flyttar kameran och ritar markeringen, men ger ingen snabbmeny.
    var isSettingsPreview = false {
        didSet { updateTrackingAreas() }
    }
    /// Spotlightens viloläge i förhandsvisningen; pekaren över vyn tar över medan den är där.
    var previewSpotlightRest: CGPoint?
    private var previewHover: CGPoint?
    private var previewTracking: NSTrackingArea?

    private let canvas = CALayer()
    private let contentLayer = CALayer()
    private let dimLayer = CALayer()
    private let dimMask = CALayer()
    private let outlineLayer = CAShapeLayer()
    private let cameraContainer = CALayer()
    private let cameraClip = CALayer()
    private let cameraMask = CAShapeLayer()
    private let cameraBorder = CAShapeLayer()
    private let idleTitle = CATextLayer()
    private let idleSubtitle = CATextLayer()
    private let idleImage = CALayer()
    /// Mörk ruta bakom text som ligger ovanpå en bild, så att texten går att läsa.
    private let idleTextBackdrop = CALayer()
    private var idleImageSize: CGSize = .zero
    private var previewLayer: AVCaptureVideoPreviewLayer?
    /// Nedräkningen ligger över bilden men under kameran, så att du syns även under pausen.
    private let countdownLayer = CALayer()
    private let countdownMessage = CATextLayer()
    private let countdownSubtitle = CATextLayer()
    private let countdownFooter = CATextLayer()
    private let countdownTime = CATextLayer()
    private let countdownTrack = CALayer()
    private let countdownFill = CALayer()
    private var countdown: CountdownDisplay?
    /// Höjden på den riktiga scenen när den här vyn är en nedskalad förhandsvisning. Ram och skugga anges i
    /// scenens punkter och skalas då ned, så att förhandsvisningen ser ut som det publiken ser.
    var referenceHeight: CGFloat? { didSet { if referenceHeight != oldValue { relayout(animated: false) } } }
    private var pointScale: CGFloat {
        guard let ref = referenceHeight, ref > 0, bounds.height > 0 else { return 1 }
        return bounds.height / ref
    }
    /// Textläget: en ruta över hela scenen med en text, i samma stil som meddelandet när inget delas.
    private let textCardLayer = CALayer()
    private let textCardLabel = CATextLayer()
    private var textCard: String?

    /// Behålls så att IOSurface:n inte återanvänds av ScreenCaptureKit medan den visas.
    private var currentBuffer: CVPixelBuffer?
    private var sourceSize: CGSize = .zero
    private(set) var contentRect: CGRect = .zero
    private var cameraFrame: CGRect = .zero
    private var camera = CameraSettings()
    private var effects = EffectSettings()
    private var spotCenter: CGPoint?
    private var pendingFade = false
    /// Visas när ingen källa delas: text, bild, kameran eller den senaste bilden.
    private var idle: IdleMessage?
    private var idleCamera: Bool { idle?.content == .camera }
    private var showsCamera: Bool { camera.enabled || idleCamera }
    private var cameraIsLarge: Bool { idleCamera || (camera.enabled && camera.fullscreen) }

    private enum Drag {
        case none
        case camera(offset: CGSize)
        case rect(start: CGPoint)
    }
    private var drag: Drag = .none
    private(set) var isInteracting = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(canvas)

        contentLayer.contentsGravity = .resize
        canvas.addSublayer(contentLayer)

        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = 0
        dimLayer.mask = dimMask
        canvas.addSublayer(dimLayer)

        outlineLayer.fillColor = nil
        outlineLayer.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        outlineLayer.lineWidth = 2
        outlineLayer.isHidden = true
        canvas.addSublayer(outlineLayer)

        for (layer, color) in [(idleTitle, NSColor(white: 0.95, alpha: 1)), (idleSubtitle, NSColor(white: 0.72, alpha: 1))] {
            layer.alignmentMode = .center
            layer.isWrapped = true
            layer.foregroundColor = color.cgColor
            layer.isHidden = true
            canvas.addSublayer(layer)
        }
        idleTitle.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        idleSubtitle.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        idleImage.contentsGravity = .resizeAspect
        idleImage.isHidden = true
        canvas.addSublayer(idleImage)
        idleTextBackdrop.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        idleTextBackdrop.isHidden = true
        canvas.insertSublayer(idleTextBackdrop, above: idleImage)
        // Texten ska ligga ovanpå bilden.
        canvas.insertSublayer(idleTitle, above: idleTextBackdrop)
        canvas.insertSublayer(idleSubtitle, above: idleTitle)

        cameraClip.mask = cameraMask
        cameraClip.backgroundColor = NSColor.black.cgColor
        cameraContainer.addSublayer(cameraClip)
        cameraBorder.fillColor = nil
        cameraContainer.addSublayer(cameraBorder)
        cameraContainer.shadowColor = NSColor.black.cgColor
        cameraContainer.shadowRadius = 14
        cameraContainer.shadowOffset = CGSize(width: 0, height: -4)
        cameraContainer.isHidden = true
        canvas.addSublayer(cameraContainer)

        countdownLayer.isHidden = true
        for l in [countdownMessage, countdownSubtitle, countdownTime, countdownFooter] {
            l.truncationMode = .end
            countdownLayer.addSublayer(l)
        }
        countdownTrack.backgroundColor = NSColor(hex: "#2E323B")?.cgColor
        countdownTrack.addSublayer(countdownFill)
        countdownLayer.addSublayer(countdownTrack)
        canvas.insertSublayer(countdownLayer, below: cameraContainer)
        textCardLabel.alignmentMode = .center
        textCardLabel.isWrapped = true
        textCardLayer.addSublayer(textCardLabel)
        textCardLayer.isHidden = true
        canvas.insertSublayer(textCardLayer, below: countdownLayer)
        updateContentsScale()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    /// Lagren ritas i skärmens upplösning. Text ritas minst dubbelt så skarpt, eftersom scenen ofta ligger på
    /// den virtuella skärmen i 1x och skalas om av förhandsvisningen och mötesappen – annars blir den grynig.
    private func updateContentsScale() {
        let s = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for l in [canvas, outlineLayer, cameraMask, cameraBorder, dimMask] { l.contentsScale = s }
        for l in [idleTitle, idleSubtitle, countdownMessage, countdownSubtitle, countdownTime, countdownFooter, textCardLabel] {
            l.contentsScale = max(2, s)
            l.minificationFilter = .trilinear
        }
    }

    override func layout() {
        super.layout()
        relayout(animated: false)
    }

    // MARK: - Innehåll

    func display(_ pixelBuffer: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if pendingFade {
            let t = CATransition()
            t.type = .fade
            t.duration = 0.18
            contentLayer.add(t, forKey: "switch")
            pendingFade = false
        }
        contentLayer.contents = surface
        currentBuffer = pixelBuffer
        if idle != nil { hideIdle() }
        if size != sourceSize {
            sourceSize = size
            relayout(animated: false)
        }
        CATransaction.commit()
    }

    /// Nästa bild tonas in i stället för att klippas in.
    func prepareForSwitch() { pendingFade = true }

    /// Visar meddelandet för när ingen källa delas.
    func showIdle(_ message: IdleMessage) {
        // Samma meddelande igen (förhandsvisningar uppdateras ofta): låt en animation fortsätta i stället för att börja om.
        if message == idle { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        idle = message
        let image = message.imageData.flatMap { NSImage(data: $0) }
        let showsImage = message.content == .image && image != nil
        idleImage.removeAnimation(forKey: "frames")
        if showsImage, let data = message.imageData, let animation = animatedImage(for: data) {
            idleImage.contents = animation.frames.first
            idleImage.add(animation.contentsAnimation(), forKey: "frames")
        }
        let showsText = message.content == .text || (message.content == .image && (image == nil || message.textOnImage))
        idleImageSize = image?.size ?? .zero
        if message.content != .lastFrame {
            contentLayer.contents = nil
            currentBuffer = nil
            sourceSize = .zero
        }
        idleTitle.string = message.title
        idleSubtitle.string = message.subtitle
        idleTitle.isHidden = !showsText || message.title.isEmpty
        idleSubtitle.isHidden = !showsText || message.subtitle.isEmpty
        if idleImage.animation(forKey: "frames") == nil {
            idleImage.contents = showsImage ? image : nil
        }
        idleImage.isHidden = !showsImage
        relayout(animated: false)
        CATransaction.commit()
    }

    /// Senast avkodade animerade bild, så att en ändrad rubrik inte avkodar om alla bildrutor.
    private var animationCache: (data: Data, image: AnimatedImage?)?

    private func animatedImage(for data: Data) -> AnimatedImage? {
        if let cache = animationCache, cache.data == data { return cache.image }
        let image = AnimatedImage.decode(data)
        animationCache = (data, image)
        return image
    }

    /// Visar en stillbild som innehåll (används av förhandsvisningarna i kontrollpanelen).
    func displayStill(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = image
        currentBuffer = nil
        sourceSize = CGSize(width: image.width, height: image.height)
        relayout(animated: false)
        CATransaction.commit()
    }

    func clearIdle() {
        guard idle != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hideIdle()
        CATransaction.commit()
    }

    private func hideIdle() {
        idle = nil
        idleTitle.isHidden = true
        idleSubtitle.isHidden = true
        idleImage.isHidden = true
        idleTextBackdrop.isHidden = true
        idleImage.removeAnimation(forKey: "frames")
        idleImage.contents = nil
        relayout(animated: false)
    }

    func setBackground(_ hex: String) {
        canvas.backgroundColor = (NSColor(hex: hex) ?? .black).cgColor
        textCardLayer.backgroundColor = canvas.backgroundColor
    }

    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer?.removeFromSuperlayer()
        layer.videoGravity = .resizeAspectFill
        cameraClip.addSublayer(layer)
        previewLayer = layer
        relayout(animated: false)
    }

    // MARK: - Inställningar

    func apply(camera newCamera: CameraSettings, animated: Bool) {
        camera = newCamera
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.3)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        layoutCamera()
        contentLayer.opacity = cameraIsLarge ? 0.15 : 1
        CATransaction.commit()
    }

    func apply(effects newEffects: EffectSettings) {
        effects = newEffects
        renderEffects()
    }

    func setSpotlight(center: CGPoint?) {
        if let a = center, let b = spotCenter, abs(a.x - b.x) < 0.0005, abs(a.y - b.y) < 0.0005 { return }
        if center == nil && spotCenter == nil { return }
        spotCenter = center
        renderEffects()
    }

    /// Innehållsytan i skärmkoordinater (för att spotlight ska kunna följa musen även över scenen).
    func contentRectOnScreen() -> CGRect? {
        guard let window, sourceSize != .zero else { return nil }
        return window.convertToScreen(convert(contentRect, to: nil))
    }

    // MARK: - Layout

    private func relayout(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        let b = bounds
        canvas.frame = b
        contentRect = sourceSize == .zero ? b : AVMakeRect(aspectRatio: sourceSize, insideRect: b)
        contentLayer.frame = contentRect
        dimLayer.frame = contentRect
        dimMask.frame = dimLayer.bounds
        outlineLayer.frame = contentRect
        contentLayer.opacity = cameraIsLarge ? 0.15 : 1
        let titleSize = max(14, b.height * 0.055)
        let subtitleSize = max(11, b.height * 0.032)
        idleTitle.fontSize = titleSize
        idleSubtitle.fontSize = subtitleSize
        // Text ovanpå en bild kan ha flyttat justeringen; vanlig text är alltid centrerad.
        idleTitle.alignmentMode = .center
        idleSubtitle.alignmentMode = .center
        let titleHeight = titleSize * 2.6
        let subtitleHeight = subtitleSize * 2.6
        let hasSubtitle = !idleSubtitle.isHidden
        let blockTop = b.midY + (hasSubtitle ? (titleHeight + subtitleHeight) / 2 : titleHeight / 2)
        idleTitle.frame = CGRect(x: b.width * 0.08, y: blockTop - titleHeight, width: b.width * 0.84, height: titleHeight)
        idleSubtitle.frame = CGRect(x: b.width * 0.08, y: blockTop - titleHeight - subtitleHeight, width: b.width * 0.84, height: subtitleHeight)
        idleImage.frame = b.insetBy(dx: b.width * 0.12, dy: b.height * 0.12)
        layoutTextOnImage()
        layoutCamera()
        renderEffects()
        layoutCountdown()
        layoutTextCard()
        CATransaction.commit()
    }

    /// Rubrik och undertext ovanpå bilden, på vald plats inom den del av lagret där bilden faktiskt syns.
    private func layoutTextOnImage() {
        guard let message = idle, message.content == .image, message.textOnImage, !idleImage.isHidden,
              idleImageSize.width > 0, !(idleTitle.isHidden && idleSubtitle.isHidden) else {
            idleTextBackdrop.isHidden = true
            return
        }
        let imageRect = AVMakeRect(aspectRatio: idleImageSize, insideRect: idleImage.frame)
        let pos = message.textPosition.anchor
        let titleFont = NSFont.systemFont(ofSize: max(12, imageRect.height * 0.075), weight: .semibold)
        let subtitleFont = NSFont.systemFont(ofSize: max(10, imageRect.height * 0.045), weight: .regular)
        let maxWidth = imageRect.width * 0.8
        func measure(_ text: String, _ font: NSFont, hidden: Bool) -> CGSize {
            guard !hidden, !text.isEmpty else { return .zero }
            let r = NSAttributedString(string: text, attributes: [.font: font])
                .boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
            return CGSize(width: ceil(r.width) + 2, height: ceil(r.height) + 2)
        }
        let t = measure(message.title, titleFont, hidden: idleTitle.isHidden)
        let s = measure(message.subtitle, subtitleFont, hidden: idleSubtitle.isHidden)
        let gap: CGFloat = t.height > 0 && s.height > 0 ? imageRect.height * 0.012 : 0
        let pad = imageRect.height * 0.035
        let blockW = max(t.width, s.width)
        let blockH = t.height + gap + s.height
        let margin = imageRect.height * 0.05
        // Blockets ytterkant (med ruta) placeras inom bilden; mitten-lägen centreras.
        let outerW = blockW + pad * 2, outerH = blockH + pad * 2
        let x = imageRect.minX + margin + (imageRect.width - margin * 2 - outerW) * pos.x
        let yTop = imageRect.maxY - margin - (imageRect.height - margin * 2 - outerH) * pos.y
        idleTextBackdrop.frame = CGRect(x: x, y: yTop - outerH, width: outerW, height: outerH)
        idleTextBackdrop.cornerRadius = pad * 0.8
        idleTextBackdrop.isHidden = false
        let align: CATextLayerAlignmentMode = pos.x == 0 ? .left : (pos.x == 1 ? .right : .center)
        for (layer, font) in [(idleTitle, titleFont), (idleSubtitle, subtitleFont)] {
            layer.font = font
            layer.fontSize = font.pointSize
            layer.alignmentMode = align
        }
        idleTitle.frame = CGRect(x: x + pad, y: yTop - pad - t.height, width: blockW, height: t.height)
        idleSubtitle.frame = CGRect(x: x + pad, y: yTop - pad - t.height - gap - s.height, width: blockW, height: s.height)
    }

    // MARK: - Textläge

    func setTextCard(_ text: String?) {
        guard text != textCard else { return }
        textCard = text
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutTextCard()
        CATransaction.commit()
    }

    private func layoutTextCard() {
        guard let text = textCard else { textCardLayer.isHidden = true; return }
        textCardLayer.isHidden = false
        let b = bounds
        textCardLayer.frame = b
        textCardLayer.backgroundColor = canvas.backgroundColor
        // Vanlig sträng: CATextLayer radbryter den, men inte en attribuerad sträng.
        let font = NSFont.systemFont(ofSize: max(14, b.height * 0.065), weight: .semibold)
        let width = b.width * 0.84
        let height = ceil(NSAttributedString(string: text, attributes: [.font: font])
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
            .height) + 4
        textCardLabel.font = font
        textCardLabel.fontSize = font.pointSize
        textCardLabel.foregroundColor = NSColor(white: 0.95, alpha: 1).cgColor
        textCardLabel.string = text
        textCardLabel.frame = CGRect(x: (b.width - width) / 2, y: b.midY - min(height, b.height * 0.9) / 2,
                                     width: width, height: min(height, b.height * 0.9))
    }

    // MARK: - Nedräkning

    func setCountdown(_ display: CountdownDisplay?) {
        guard display != countdown else { return }
        countdown = display
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutCountdown()
        CATransaction.commit()
    }

    private func layoutCountdown() {
        guard let c = countdown else { countdownLayer.isHidden = true; return }
        countdownLayer.isHidden = false
        let b = bounds
        let h = b.height
        let messageColor = NSColor(hex: c.messageColor) ?? .white
        let subtitleColor = NSColor(hex: c.subtitleColor) ?? .lightGray
        let timeColor = NSColor(hex: c.timeColor) ?? .orange
        countdownLayer.backgroundColor = (NSColor(hex: c.backgroundColor) ?? .black).cgColor
        countdownFill.backgroundColor = timeColor.cgColor
        countdownTrack.backgroundColor = timeColor.withAlphaComponent(0.22).cgColor

        func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, digits: Bool = false) -> NSAttributedString {
            let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
            return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        }
        /// Placerar ett textlager uppifrån och nedåt; tomma texter tar ingen plats.
        func place(_ layer: CATextLayer, _ string: NSAttributedString, x: CGFloat, width: CGFloat, top: inout CGFloat, gap: CGFloat = 0) {
            layer.isHidden = string.length == 0
            guard string.length > 0 else { return }
            let height = ceil(string.size().height)
            layer.string = string
            layer.frame = CGRect(x: x, y: top - height, width: width, height: height)
            top -= height + gap
        }
        func height(_ string: NSAttributedString) -> CGFloat { string.length == 0 ? 0 : ceil(string.size().height) }

        // CATextLayer följer inte styckeformatets justering, bara alignmentMode.
        let align: CATextLayerAlignmentMode = c.placement == .full ? .center : .right
        for l in [countdownMessage, countdownSubtitle, countdownTime, countdownFooter] { l.alignmentMode = align }
        let footerColor = NSColor(hex: c.footerColor) ?? .lightGray

        switch c.placement {
        case .full:
            countdownLayer.frame = b
            countdownLayer.cornerRadius = 0
            let width = b.width * 0.84
            let x = (b.width - width) / 2
            let finished = c.time == nil
            let msg = text(c.message, size: h * (finished ? 0.075 : 0.05), weight: .semibold, color: messageColor)
            let sub = text(c.subtitle, size: h * 0.032, weight: .regular, color: subtitleColor)
            let digits = text(c.time ?? "", size: h * 0.26, weight: .bold, color: timeColor, digits: true)
            let foot = text(c.footer, size: h * 0.036, weight: .medium, color: footerColor, digits: true)
            let subGap = h * 0.012
            let barH = max(4, h * 0.011)
            let gap = h * 0.03
            let footGap = h * 0.035
            var total = height(msg) + height(sub) + (sub.length > 0 ? subGap : 0)
            if !finished { total += height(digits) + gap + barH }
            if foot.length > 0 { total += footGap + height(foot) }
            var top = b.midY + total / 2
            place(countdownMessage, msg, x: x, width: width, top: &top, gap: sub.length > 0 ? subGap : 0)
            place(countdownSubtitle, sub, x: x, width: width, top: &top)
            place(countdownTime, digits, x: x, width: width, top: &top, gap: gap)
            countdownTrack.isHidden = finished
            if !finished {
                let barW = b.width * 0.36
                countdownTrack.frame = CGRect(x: b.midX - barW / 2, y: top - barH, width: barW, height: barH)
                countdownTrack.cornerRadius = barH / 2
                countdownFill.frame = CGRect(x: 0, y: 0, width: barW * CGFloat(min(max(c.progress, 0), 1)), height: barH)
                countdownFill.cornerRadius = barH / 2
                top -= barH
            }
            top -= footGap
            place(countdownFooter, foot, x: x, width: width, top: &top)

        case .corner:
            let msg = text(c.message, size: h * 0.024, weight: .medium, color: messageColor)
            let sub = text(c.subtitle, size: h * 0.02, weight: .regular, color: subtitleColor)
            let digits = text(c.time ?? "", size: h * 0.06, weight: .bold, color: timeColor, digits: true)
            let foot = text(c.footer, size: h * 0.02, weight: .medium, color: footerColor, digits: true)
            let pad = h * 0.018
            let maxWidth = b.width * 0.3
            let contentW = min(max(msg.size().width, sub.size().width, digits.size().width, foot.size().width).rounded(.up), maxWidth)
            let w = contentW + pad * 2
            let boxH = height(msg) + height(sub) + height(digits) + height(foot) + pad * 1.4
            let m = min(b.width, b.height) * 0.03
            countdownLayer.frame = CGRect(x: b.width - m - w, y: b.height - m - boxH, width: w, height: boxH)
            countdownLayer.cornerRadius = h * 0.014
            var top = boxH - pad * 0.7
            place(countdownMessage, msg, x: pad, width: contentW, top: &top)
            place(countdownSubtitle, sub, x: pad, width: contentW, top: &top)
            place(countdownTime, digits, x: pad, width: contentW, top: &top)
            place(countdownFooter, foot, x: pad, width: contentW, top: &top)
            countdownTrack.isHidden = true
        }
    }

    private func layoutCamera() {
        cameraContainer.isHidden = !showsCamera
        guard showsCamera else { return }
        let b = bounds
        let ratio = camera.aspect.ratio
        var h: CGFloat
        var w: CGFloat
        let center: CGPoint
        // "Bara jag" har egen storlek och position; i övrigt gäller samma inställningar som för den lilla bubblan.
        let size = cameraIsLarge ? camera.fullSize : camera.size
        let (centerX, centerY) = cameraIsLarge ? (camera.fullCenterX, camera.fullCenterY) : (camera.centerX, camera.centerY)
        h = b.height * size
        w = h * ratio
        let maxW = b.width * (cameraIsLarge ? 0.96 : 0.9)
        if w > maxW { w = maxW; h = w / ratio }
        let m = min(b.width, b.height) * (cameraIsLarge ? 0.02 : 0.03)
        let cx = min(max(centerX * b.width, w / 2 + m), b.width - w / 2 - m)
        let cyTop = min(max(centerY * b.height, h / 2 + m), b.height - h / 2 - m)
        center = CGPoint(x: cx, y: b.height - cyTop)
        let frame = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        cameraFrame = frame
        cameraContainer.frame = frame

        let local = CGRect(origin: .zero, size: frame.size)
        let path = ShapePaths.path(for: camera.shape, in: local)
        cameraClip.frame = local
        cameraMask.frame = local
        cameraMask.path = path
        cameraBorder.frame = local
        cameraBorder.path = path
        // Ramen följer bubblans storlek i "Bara jag", så att den ser lika tjock ut i förhållande till bilden.
        cameraBorder.lineWidth = camera.borderWidth * pointScale * (cameraIsLarge ? min(4, max(1, camera.fullSize / max(camera.size, 0.08))) : 1)
        cameraContainer.shadowRadius = 14 * pointScale
        cameraContainer.shadowOffset = CGSize(width: 0, height: -4 * pointScale)
        cameraBorder.isHidden = camera.borderWidth <= 0
        cameraBorder.strokeColor = (NSColor(hex: camera.borderColor) ?? .white).cgColor
        cameraContainer.shadowPath = path
        cameraContainer.shadowOpacity = camera.shadow ? 0.5 : 0

        if let pl = previewLayer {
            let z = CGFloat(max(1, camera.zoom))
            pl.bounds = CGRect(x: 0, y: 0, width: w * z, height: h * z)
            pl.position = CGPoint(x: w / 2, y: h / 2)
            pl.setAffineTransform(camera.mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        }
    }

    private func renderEffects() {
        let aspect = contentRect.width / max(contentRect.height, 1)
        var image: CGImage?
        switch effects.mode {
        case .off:
            break
        case .rect:
            if let r = effects.rect { image = EffectMask.rect(aspect: aspect, rect: r) }
        case .spotlight:
            if let c = spotCenter {
                image = EffectMask.spotlight(aspect: aspect, center: c, radius: effects.spotlightRadius, feather: effects.feather)
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let image { dimMask.contents = image }
        if effects.mode == .rect, let r = effects.rect, sourceSize != .zero {
            let s = contentRect.size
            let rr = CGRect(x: r.minX * s.width, y: (1 - r.maxY) * s.height, width: r.width * s.width, height: r.height * s.height)
            let radius = min(10 * s.width / 800, rr.width / 2, rr.height / 2)
            outlineLayer.path = CGPath(roundedRect: rr, cornerWidth: radius, cornerHeight: radius, transform: nil)
            outlineLayer.isHidden = false
        } else {
            outlineLayer.isHidden = true
        }
        CATransaction.commit()

        let target: Float = (image != nil && sourceSize != .zero) ? Float(effects.dimOpacity) : 0
        if dimLayer.opacity != target {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            dimLayer.opacity = target
            CATransaction.commit()
        }
    }

    // MARK: - Mus

    /// Punkt i vyn → normaliserad punkt i källan (origo uppe till vänster).
    private func normalizedInContent(_ p: CGPoint) -> CGPoint {
        let x = (p.x - contentRect.minX) / max(contentRect.width, 1)
        let y = (contentRect.maxY - p.y) / max(contentRect.height, 1)
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    /// Normaliserad källpunkt för en punkt i scenen, om punkten ligger på källans bild.
    func contentPoint(forStagePoint p: CGPoint) -> CGPoint? {
        guard sourceSize != .zero, contentRect.contains(p) else { return nil }
        return normalizedInContent(p)
    }

    // Musen hanteras med punkter i scenens koordinater, så att förhandsvisningen kan skicka vidare sina händelser.

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let previewTracking { removeTrackingArea(previewTracking) }
        previewTracking = nil
        guard isSettingsPreview else { return }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        previewTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard isSettingsPreview else { return super.mouseMoved(with: event) }
        updatePreviewHover(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard isSettingsPreview else { return super.mouseExited(with: event) }
        updatePreviewHover(nil)
    }

    /// I förhandsvisningen finns ingen delad källa att följa, så spotlighten följer pekaren över exempelfönstret.
    private func updatePreviewHover(_ p: CGPoint?) {
        previewHover = p.flatMap { contentPoint(forStagePoint: $0) }
        showPreviewSpotlight()
    }

    func showPreviewSpotlight() {
        guard effects.mode == .spotlight else { return setSpotlight(center: nil) }
        setSpotlight(center: previewHover ?? previewSpotlightRest)
    }

    override func mouseDown(with event: NSEvent) { pointerDown(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Under en dragning kommer inga mouseMoved, så spotlighten skulle annars stå still.
        if isSettingsPreview { updatePreviewHover(p) }
        pointerDragged(to: p)
    }
    override func mouseUp(with event: NSEvent) { pointerUp(at: convert(event.locationInWindow, from: nil)) }

    override func scrollWheel(with event: NSEvent) {
        let step = event.hasPreciseScrollingDeltas ? 0.002 : 0.02
        // Utanför kameran går rullningen vidare, så att inställningsfönstret kan rulla över förhandsvisningen.
        if !scroll(at: convert(event.locationInWindow, from: nil), delta: Double(event.scrollingDeltaY) * step) {
            super.scrollWheel(with: event)
        }
    }

    func pointerDown(at p: CGPoint) {
        if showsCamera, cameraFrame.contains(p) {
            drag = .camera(offset: CGSize(width: p.x - cameraFrame.midX, height: p.y - cameraFrame.midY))
            isInteracting = true
        } else if effects.mode == .rect || (!isSettingsPreview && effects.mode == .off),
                  sourceSize != .zero, contentRect.contains(p) {
            // Spotlightläget ska inte bytas mot en rektangel av ett klick, och förhandsvisningen
            // byter aldrig läge: där går det bara att flytta en rektangel som redan är vald.
            drag = .rect(start: p)
            isInteracting = true
        }
    }

    func pointerDragged(to p: CGPoint) {
        switch drag {
        case .none:
            break
        case .camera(let offset):
            let cx = (p.x - offset.width) / max(bounds.width, 1)
            let cy = 1 - (p.y - offset.height) / max(bounds.height, 1)
            if cameraIsLarge {
                controller?.state.camera.fullCenterX = min(max(cx, 0), 1)
                controller?.state.camera.fullCenterY = min(max(cy, 0), 1)
            } else {
                controller?.state.camera.centerX = min(max(cx, 0), 1)
                controller?.state.camera.centerY = min(max(cy, 0), 1)
            }
        case .rect(let start):
            guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
            let a = normalizedInContent(start)
            let b = normalizedInContent(p)
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            controller?.setHighlight(r)
        }
    }

    func pointerUp(at p: CGPoint) {
        if case .rect(let start) = drag, hypot(p.x - start.x, p.y - start.y) <= 4, effects.mode == .rect, !isSettingsPreview {
            // Ett klick utan att dra tar bort markeringen.
            controller?.clearEffects()
        }
        drag = .none
        isInteracting = false
    }

    @discardableResult
    func scroll(at p: CGPoint, delta: Double) -> Bool {
        guard showsCamera, cameraFrame.contains(p), let state = controller?.state else { return false }
        isInteracting = true
        if cameraIsLarge {
            state.camera.fullSize = min(max(state.camera.fullSize + delta, 0.3), 1)
        } else {
            state.camera.size = min(max(state.camera.size + delta, 0.08), 0.8)
        }
        isInteracting = false
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        isSettingsPreview ? nil : controller?.makeQuickMenu()
    }
}

// MARK: - Former och masker

enum ShapePaths {
    static func path(for shape: CameraShape, in r: CGRect) -> CGPath {
        let m = min(r.width, r.height)
        switch shape {
        case .circle:
            return CGPath(ellipseIn: r, transform: nil)
        case .rounded:
            let c = m * 0.18
            return CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil)
        case .sharp:
            return CGPath(rect: r, transform: nil)
        case .chamfered:
            let c = m * 0.18
            return polygon([
                CGPoint(x: r.minX + c, y: r.minY), CGPoint(x: r.maxX - c, y: r.minY),
                CGPoint(x: r.maxX, y: r.minY + c), CGPoint(x: r.maxX, y: r.maxY - c),
                CGPoint(x: r.maxX - c, y: r.maxY), CGPoint(x: r.minX + c, y: r.maxY),
                CGPoint(x: r.minX, y: r.maxY - c), CGPoint(x: r.minX, y: r.minY + c),
            ])
        case .hexagon:
            let q = r.width * 0.25
            return polygon([
                CGPoint(x: r.minX + q, y: r.minY), CGPoint(x: r.maxX - q, y: r.minY),
                CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX - q, y: r.maxY),
                CGPoint(x: r.minX + q, y: r.maxY), CGPoint(x: r.minX, y: r.midY),
            ])
        }
    }

    private static func polygon(_ points: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: points)
        p.closeSubpath()
        return p
    }
}

/// Maskbilder för dimlagret: ogenomskinligt = dimmat, genomskinligt = fullt ljus.
enum EffectMask {
    private static func context(aspect: CGFloat, width: CGFloat) -> (CGContext, CGFloat, CGFloat)? {
        let w = width
        let h = max(1, (w / max(aspect, 0.01)).rounded())
        guard let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return (ctx, w, h)
    }

    static func rect(aspect: CGFloat, rect: CGRect) -> CGImage? {
        guard let (ctx, w, h) = context(aspect: aspect, width: 1000) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // CG har origo nere till vänster; rect har origo uppe till vänster.
        let r = CGRect(x: rect.minX * w, y: (1 - rect.maxY) * h, width: rect.width * w, height: rect.height * h)
        let radius = min(10, r.width / 2, r.height / 2)
        ctx.setBlendMode(.clear)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        return ctx.makeImage()
    }

    static func spotlight(aspect: CGFloat, center: CGPoint, radius: Double, feather: Double) -> CGImage? {
        guard let (ctx, w, h) = context(aspect: aspect, width: 640) else { return nil }
        let c = CGPoint(x: center.x * w, y: (1 - center.y) * h)
        let r = CGFloat(radius) * h
        let colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 1)] as CFArray
        let locations: [CGFloat] = [0, CGFloat(max(0, min(1, 1 - feather))), 1]
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) else { return nil }
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [.drawsAfterEndLocation])
        return ctx.makeImage()
    }
}

import UIKit

enum GameplayExitOverlayControllerInput {
    case up
    case down
    case left
    case right
    case select
    case cancel
}

final class GameplayExitOverlayView: UIView {
    private enum ControllerSelection {
        case restart
        case exit
        case cancel
    }

    private let session: NativeMetalPresenterSession
    private let onExitRequested: () -> Void
    private let onRestartRequested: () -> Bool
    private let panelView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let restartButton = UIButton(type: .system)
    private let exitButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private var controllerSelection: ControllerSelection = .exit
    private var actionHasBeenRequested = false
    private var suppressShowUntil: CFTimeInterval = 0
    private var suppressRawTouchHandlingUntil: CFTimeInterval = 0

    init(
        session: NativeMetalPresenterSession,
        onExitRequested: @escaping () -> Void,
        onRestartRequested: @escaping () -> Bool
    ) {
        self.session = session
        self.onExitRequested = onExitRequested
        self.onRestartRequested = onRestartRequested
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func toggle() {
        isVisible ? hide() : show()
    }

    @objc func show() {
        guard !isVisible,
              !actionHasBeenRequested,
              CACurrentMediaTime() >= suppressShowUntil else {
            NativeMetalDiagnostics.log(
                "EXIT_SHOW_SKIP",
                "visible=\(isVisible ? 1 : 0) action=\(actionHasBeenRequested ? 1 : 0) suppressUntil=\(String(format: "%.3f", suppressShowUntil)) now=\(String(format: "%.3f", CACurrentMediaTime()))"
            )
            return
        }

        NativeMetalDiagnostics.log(
            "EXIT_SHOW",
            "bounds=\(NativeMetalDiagnostics.rect(bounds)) safe=\(NativeMetalDiagnostics.insets(safeAreaInsets))"
        )
        isHidden = false
        isUserInteractionEnabled = true
        accessibilityViewIsModal = true
        controllerSelection = .exit
        updateControllerSelectionAppearance()
        suppressRawTouchHandlingUntil = CACurrentMediaTime() + 0.25
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
            self.alpha = 1
        }
    }

    @objc func hide() {
        guard isVisible, !actionHasBeenRequested else {
            NativeMetalDiagnostics.log(
                "EXIT_HIDE_SKIP",
                "visible=\(isVisible ? 1 : 0) action=\(actionHasBeenRequested ? 1 : 0)"
            )
            return
        }

        NativeMetalDiagnostics.log("EXIT_HIDE", "bounds=\(NativeMetalDiagnostics.rect(bounds))")
        suppressShowUntil = CACurrentMediaTime() + 0.35
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseIn]) {
            self.alpha = 0
        } completion: { _ in
            self.isHidden = true
            self.isUserInteractionEnabled = false
            self.accessibilityViewIsModal = false
        }
    }

    private var isVisible: Bool {
        !isHidden && alpha > 0
    }

    var isMenuVisible: Bool {
        isVisible
    }

    @discardableResult
    func handleControllerInput(_ input: GameplayExitOverlayControllerInput) -> Bool {
        guard isVisible, !actionHasBeenRequested else {
            return false
        }

        switch input {
        case .up:
            moveControllerSelection(verticalDelta: -1)
        case .down:
            moveControllerSelection(verticalDelta: 1)
        case .left:
            moveControllerSelection(horizontalDelta: -1)
        case .right:
            moveControllerSelection(horizontalDelta: 1)
        case .select:
            confirmControllerSelection()
        case .cancel:
            hide()
        }

        return true
    }

    func refreshLayoutForGeometryChange() {
        NativeMetalDiagnostics.log(
            "EXIT_REFRESH_LAYOUT",
            "bounds=\(NativeMetalDiagnostics.rect(bounds)) panel=\(NativeMetalDiagnostics.rect(panelView.frame)) visible=\(isVisible ? 1 : 0)"
        )
        superview?.setNeedsLayout()
        superview?.layoutIfNeeded()
        setNeedsLayout()
        layoutIfNeeded()
        panelView.setNeedsLayout()
        panelView.layoutIfNeeded()
    }

    @discardableResult
    func handleRawTouchEnded(from event: UIEvent) -> Bool {
        guard isVisible,
              CACurrentMediaTime() >= suppressRawTouchHandlingUntil,
              let touches = event.allTouches else {
            NativeMetalDiagnostics.log(
                "EXIT_RAW_SKIP",
                "visible=\(isVisible ? 1 : 0) suppressed=\(CACurrentMediaTime() < suppressRawTouchHandlingUntil ? 1 : 0) touches=\(event.allTouches?.count ?? 0)"
            )
            return false
        }

        refreshLayoutForGeometryChange()
        for touch in touches where touch.phase == .ended {
            if handleTouchEnded(at: touch.location(in: self)) {
                NativeMetalDiagnostics.log("EXIT_RAW_HANDLED", "touch=\(NativeMetalDiagnostics.touch(touch, in: self))")
                return true
            }
        }

        NativeMetalDiagnostics.log("EXIT_RAW_UNHANDLED", "touches=\(touches.count)")
        return false
    }

    @discardableResult
    func handleBridgedTouchEnded(at point: CGPoint) -> Bool {
        guard isVisible,
              CACurrentMediaTime() >= suppressRawTouchHandlingUntil else {
            NativeMetalDiagnostics.log(
                "EXIT_BRIDGED_SKIP",
                "point=\(NativeMetalDiagnostics.point(point)) visible=\(isVisible ? 1 : 0) suppressed=\(CACurrentMediaTime() < suppressRawTouchHandlingUntil ? 1 : 0)"
            )
            return false
        }

        refreshLayoutForGeometryChange()
        let handled = handleTouchEnded(at: point)
        NativeMetalDiagnostics.log(
            "EXIT_BRIDGED_RESULT",
            "point=\(NativeMetalDiagnostics.point(point)) handled=\(handled ? 1 : 0)"
        )
        return handled
    }

    @discardableResult
    private func handleTouchEnded(at point: CGPoint) -> Bool {
        let restartFrame = restartButton.convert(restartButton.bounds, to: self).insetBy(dx: -12, dy: -10)
        let exitFrame = exitButton.convert(exitButton.bounds, to: self).insetBy(dx: -12, dy: -10)
        let cancelFrame = cancelButton.convert(cancelButton.bounds, to: self).insetBy(dx: -12, dy: -10)
        let panelFrame = panelView.convert(panelView.bounds, to: self)
        NativeMetalDiagnostics.log(
            "EXIT_HIT_TEST",
            "point=\(NativeMetalDiagnostics.point(point)) restart=\(NativeMetalDiagnostics.rect(restartFrame)) exit=\(NativeMetalDiagnostics.rect(exitFrame)) cancel=\(NativeMetalDiagnostics.rect(cancelFrame)) panel=\(NativeMetalDiagnostics.rect(panelFrame))"
        )

        if restartFrame.contains(point) {
            confirmRestart()
            return true
        }
        if exitFrame.contains(point) {
            confirmExit()
            return true
        }
        if cancelFrame.contains(point) {
            hide()
            return true
        }
        if !panelFrame.contains(point) {
            hide()
            return true
        }

        return false
    }

    private func configure() {
        alpha = 0
        isHidden = true
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.36)

        let dismissButton = UIButton(type: .custom)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.addTarget(self, action: #selector(hide), for: .touchUpInside)
        addSubview(dismissButton)

        panelView.translatesAutoresizingMaskIntoConstraints = false
        panelView.layer.cornerRadius = 18
        panelView.layer.cornerCurve = .continuous
        panelView.layer.masksToBounds = true
        addSubview(panelView)

        let actionStack = UIStackView(arrangedSubviews: [restartButton, exitButton])
        actionStack.axis = .horizontal
        actionStack.alignment = .fill
        actionStack.distribution = .fillEqually
        actionStack.spacing = 8

        let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel, actionStack, cancelButton])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8
        stack.setCustomSpacing(12, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panelView.contentView.addSubview(stack)

        titleLabel.text = session.isDashboard ? "Exit Dashboard?" : "Exit Gameplay?"
        titleLabel.textColor = .white
        titleLabel.font = .preferredFont(forTextStyle: .headline).withWeight(.bold)
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center

        messageLabel.text = session.isDashboard ?
            "DukeX will stop the dashboard and return to the Games tab." :
            "DukeX will stop \(session.displayTitle) and return to the Games tab. Unsaved progress may be lost."
        messageLabel.textColor = UIColor.white.withAlphaComponent(0.78)
        messageLabel.font = .preferredFont(forTextStyle: .footnote)
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center

        restartButton.configuration = primaryButtonConfiguration(
            title: session.isDashboard ? "Restart Dashboard" : "Restart Game",
            color: .systemGreen
        )
        restartButton.layer.cornerCurve = .continuous
        restartButton.addTarget(self, action: #selector(confirmRestart), for: .touchUpInside)

        exitButton.configuration = primaryButtonConfiguration(
            title: session.isDashboard ? "Exit Dashboard" : "Exit Game",
            color: .systemRed
        )
        exitButton.layer.cornerCurve = .continuous
        exitButton.addTarget(self, action: #selector(confirmExit), for: .touchUpInside)

        cancelButton.configuration = secondaryButtonConfiguration(title: "Cancel")
        cancelButton.layer.cornerCurve = .continuous
        cancelButton.addTarget(self, action: #selector(hide), for: .touchUpInside)

        NSLayoutConstraint.activate([
            dismissButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            dismissButton.topAnchor.constraint(equalTo: topAnchor),
            dismissButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            panelView.centerXAnchor.constraint(equalTo: centerXAnchor),
            panelView.centerYAnchor.constraint(equalTo: centerYAnchor),
            panelView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -42),
            panelView.widthAnchor.constraint(lessThanOrEqualToConstant: 340),

            stack.leadingAnchor.constraint(equalTo: panelView.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: panelView.contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: panelView.contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: panelView.contentView.bottomAnchor, constant: -14),
            restartButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            exitButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])

        accessibilityLabel = session.isDashboard ? "Exit Dashboard Menu" : "Exit Gameplay Menu"
        updateControllerSelectionAppearance()
    }

    @objc private func confirmExit() {
        guard !actionHasBeenRequested else {
            return
        }

        NativeMetalDiagnostics.log("EXIT_CONFIRM", "dashboard=\(session.isDashboard ? 1 : 0)")
        actionHasBeenRequested = true
        restartButton.isEnabled = false
        exitButton.isEnabled = false
        cancelButton.isEnabled = false
        titleLabel.text = "Exiting..."
        messageLabel.text = session.isDashboard ?
            "Stopping the dashboard and returning to Games." :
            "Stopping \(session.displayTitle) and returning to Games."
        exitButton.configuration = primaryButtonConfiguration(title: "Exiting", color: .systemGray)
        onExitRequested()
    }

    @objc private func confirmRestart() {
        guard !actionHasBeenRequested else {
            return
        }

        NativeMetalDiagnostics.log("RESTART_CONFIRM", "dashboard=\(session.isDashboard ? 1 : 0)")
        actionHasBeenRequested = true
        restartButton.isEnabled = false
        exitButton.isEnabled = false
        cancelButton.isEnabled = false
        titleLabel.text = "Restarting..."
        messageLabel.text = session.isDashboard ?
            "Restarting the dashboard." :
            "Restarting \(session.displayTitle)."
        restartButton.configuration = primaryButtonConfiguration(title: "Restarting", color: .systemGray)
        guard onRestartRequested() else {
            NativeMetalDiagnostics.log("RESTART_RESULT", "success=0")
            showRestartUnavailable()
            return
        }

        NativeMetalDiagnostics.log("RESTART_RESULT", "success=1")
        finishRestartRequest()
    }

    private func finishRestartRequest() {
        suppressShowUntil = CACurrentMediaTime() + 0.35
        layer.removeAllAnimations()
        panelView.layer.removeAllAnimations()
        alpha = 0
        isHidden = true
        isUserInteractionEnabled = false
        accessibilityViewIsModal = false
        restoreDefaultState()
    }

    private func showRestartUnavailable() {
        actionHasBeenRequested = false
        restartButton.isEnabled = true
        exitButton.isEnabled = true
        cancelButton.isEnabled = true
        titleLabel.text = "Restart Unavailable"
        messageLabel.text = "DukeX could not restart this session without leaving gameplay."
        restartButton.configuration = primaryButtonConfiguration(
            title: session.isDashboard ? "Restart Dashboard" : "Restart Game",
            color: .systemGreen
        )
        updateControllerSelectionAppearance()
    }

    private func restoreDefaultState() {
        actionHasBeenRequested = false
        restartButton.isEnabled = true
        exitButton.isEnabled = true
        cancelButton.isEnabled = true
        controllerSelection = .exit
        titleLabel.text = session.isDashboard ? "Exit Dashboard?" : "Exit Gameplay?"
        messageLabel.text = session.isDashboard ?
            "DukeX will stop the dashboard and return to the Games tab." :
            "DukeX will stop \(session.displayTitle) and return to the Games tab. Unsaved progress may be lost."
        restartButton.configuration = primaryButtonConfiguration(
            title: session.isDashboard ? "Restart Dashboard" : "Restart Game",
            color: .systemGreen
        )
        exitButton.configuration = primaryButtonConfiguration(
            title: session.isDashboard ? "Exit Dashboard" : "Exit Game",
            color: .systemRed
        )
        cancelButton.configuration = secondaryButtonConfiguration(title: "Cancel")
        updateControllerSelectionAppearance()
    }

    private func moveControllerSelection(horizontalDelta: Int = 0, verticalDelta: Int = 0) {
        if verticalDelta != 0 {
            controllerSelection = controllerSelection == .cancel ? .exit : .cancel
            updateControllerSelectionAppearance()
            return
        }

        guard horizontalDelta != 0 else {
            return
        }

        switch controllerSelection {
        case .restart:
            controllerSelection = .exit
        case .exit:
            controllerSelection = .restart
        case .cancel:
            controllerSelection = horizontalDelta < 0 ? .restart : .exit
        }
        updateControllerSelectionAppearance()
    }

    private func confirmControllerSelection() {
        switch controllerSelection {
        case .restart:
            confirmRestart()
        case .exit:
            confirmExit()
        case .cancel:
            hide()
        }
    }

    private func updateControllerSelectionAppearance() {
        updateControllerSelectionAppearance(for: restartButton, selected: controllerSelection == .restart)
        updateControllerSelectionAppearance(for: exitButton, selected: controllerSelection == .exit)
        updateControllerSelectionAppearance(for: cancelButton, selected: controllerSelection == .cancel)
    }

    private func updateControllerSelectionAppearance(for button: UIButton, selected: Bool) {
        button.layer.borderColor = UIColor.white.withAlphaComponent(selected ? 0.92 : 0).cgColor
        button.layer.borderWidth = selected ? 2 : 0
        button.layer.shadowColor = UIColor.white.cgColor
        button.layer.shadowOpacity = selected ? 0.28 : 0
        button.layer.shadowRadius = selected ? 8 : 0
        button.layer.shadowOffset = .zero
        button.transform = selected ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
    }

    private func primaryButtonConfiguration(title: String, color: UIColor) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        configuration.attributedTitle = AttributedString(title, attributes: buttonTitleAttributes())
        configuration.baseBackgroundColor = color
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10)
        return configuration
    }

    private func secondaryButtonConfiguration(title: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.gray()
        configuration.attributedTitle = AttributedString(title, attributes: buttonTitleAttributes())
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        return configuration
    }

    private func buttonTitleAttributes() -> AttributeContainer {
        var attributes = AttributeContainer()
        attributes.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        return attributes
    }
}

extension NativeMetalPresenterSession {
    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "the running game" : trimmedTitle
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let traits = [UIFontDescriptor.TraitKey.weight: weight]
        let descriptor = fontDescriptor.addingAttributes([.traits: traits])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

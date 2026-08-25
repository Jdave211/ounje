import SwiftUI
import Foundation
import UIKit
import AVFoundation

struct PrepFoodCameraCaptureView: View {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void
    let onSelectGallery: (() -> Void)?
    @StateObject private var camera = PrepFoodCameraController()
    @State private var showsFramingPrompt = true

    init(
        _ onCapture: @escaping (UIImage) -> Void,
        onCancel: @escaping () -> Void,
        onSelectGallery: (() -> Void)? = nil
    ) {
        self.onCapture = onCapture
        self.onCancel = onCancel
        self.onSelectGallery = onSelectGallery
    }

    var body: some View {
        ZStack {
            PrepFoodCameraPreview(session: camera.session)
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color.black.opacity(0.22),
                    Color.clear,
                    Color.black.opacity(0.34)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.top, 64)

                Spacer(minLength: 0)

                VStack(spacing: 22) {
                    HStack(spacing: 16) {
                        scannerOptionTile(
                            title: "Scan",
                            systemImage: "viewfinder",
                            isSelected: true
                        )
                        .allowsHitTesting(false)

                        Button {
                            onSelectGallery?()
                        } label: {
                            scannerOptionTile(
                                title: "Gallery",
                                systemImage: "photo.on.rectangle.angled",
                                isSelected: false
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(onSelectGallery == nil)
                        .opacity(onSelectGallery == nil ? 0.42 : 0.74)
                    }

                    HStack(spacing: 22) {
                        Circle()
                            .fill(Color.clear)
                            .frame(width: 54, height: 54)

                        Button {
                            camera.capturePhoto()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.36))
                                    .frame(width: 94, height: 94)

                                Circle()
                                    .fill(Color.white.opacity(0.96))
                                    .frame(width: 72, height: 72)
                                    .overlay {
                                        Circle()
                                            .stroke(Color.black.opacity(0.72), lineWidth: 3)
                                    }
                            }
                            .shadow(color: .black.opacity(0.32), radius: 12, x: 0, y: 6)
                        }
                        .buttonStyle(.plain)
                        .disabled(camera.isCapturing)
                        .opacity(camera.isCapturing ? 0.66 : 1)

                        Button {
                            camera.toggleTorch()
                        } label: {
                            Image(systemName: camera.isTorchOn ? "bolt.fill" : "bolt")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(
                                    camera.supportsTorch
                                        ? (camera.isTorchOn ? Color.black.opacity(0.82) : Color.white)
                                        : .white.opacity(0.42)
                                )
                                .frame(width: 54, height: 54)
                                .background(
                                    Circle()
                                        .fill(camera.isTorchOn ? Color.white.opacity(0.9) : Color.black.opacity(0.32))
                                )
                                .overlay {
                                    Circle()
                                        .stroke(Color.white.opacity(camera.isTorchOn ? 0.34 : 0.18), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(camera.isCapturing || !camera.supportsTorch)
                        .opacity(camera.isCapturing ? 0.66 : 1)
                    }
                }
                .padding(.bottom, 34)
            }

            ScannerCornerBrackets()
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                .frame(width: 258, height: 328)
                .shadow(color: .black.opacity(0.28), radius: 7, x: 0, y: 3)
                .allowsHitTesting(false)

            Text("Place the meal in frame")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.36))
                )
                .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 3)
                .opacity(showsFramingPrompt ? 1 : 0)
                .scaleEffect(showsFramingPrompt ? 1 : 0.96)
                .animation(.easeOut(duration: 0.24), value: showsFramingPrompt)
                .allowsHitTesting(false)

            if let errorMessage = camera.errorMessage {
                VStack {
                    Spacer()
                    Text(errorMessage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.black.opacity(0.62))
                        )
                        .padding(.horizontal, 24)
                        .padding(.bottom, 158)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            camera.onCapture = onCapture
            camera.onCancel = onCancel
            camera.start()
            showsFramingPrompt = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.65) {
                showsFramingPrompt = false
            }
        }
        .onDisappear {
            camera.stop()
        }
    }

    private var header: some View {
        HStack {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.black.opacity(0.28)))
            }
            .buttonStyle(.plain)

            Spacer()

            SleeScriptDisplayText("Ounje", size: 34, color: .white)
                .shadow(color: .black.opacity(0.26), radius: 8, x: 0, y: 2)

            Spacer()

            Color.clear
                .frame(width: 56, height: 56)
        }
    }

    private func scannerOptionTile(title: String, systemImage: String, isSelected: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isSelected ? .black : .white)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.92) : Color.white.opacity(0.14))
                )

            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(isSelected ? 0.96 : 0.74))
        }
        .frame(width: 86, height: 72)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(isSelected ? 0.28 : 0.2))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(isSelected ? 0.24 : 0.13), lineWidth: 1)
        }
    }
}

private struct PrepFoodCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

private final class PrepFoodCameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    var onCapture: ((UIImage) -> Void)?
    var onCancel: (() -> Void)?

    @Published var isCapturing = false
    @Published var errorMessage: String?
    @Published var supportsTorch = false
    @Published var isTorchOn = false

    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "ounje.food-camera.session")
    private var didConfigure = false
    private var captureDevice: AVCaptureDevice?
    private var torchEnabled = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureAndStart()
                    } else {
                        self?.errorMessage = "Camera access is off for Ounje."
                    }
                }
            }
        default:
            errorMessage = "Camera access is off for Ounje."
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.setTorchOn(false)
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func capturePhoto() {
        guard didConfigure else {
            errorMessage = "Camera is still warming up."
            return
        }
        guard !isCapturing else { return }
        isCapturing = true
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off
        output.capturePhoto(with: settings, delegate: self)
    }

    func toggleTorch() {
        queue.async { [weak self] in
            guard let self else { return }
            self.setTorchOn(!self.torchEnabled)
        }
    }

    private func configureAndStart() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.didConfigure {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo

                defer {
                    self.session.commitConfiguration()
                }

                guard
                    let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ??
                        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                else {
                    DispatchQueue.main.async {
                        self.errorMessage = "Camera unavailable on this device."
                    }
                    return
                }

                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    self.captureDevice = device
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                    }
                    if self.session.canAddOutput(self.output) {
                        self.session.addOutput(self.output)
                    }
                    self.didConfigure = true
                    let supportsTorch = device.hasTorch && device.isTorchAvailable
                    DispatchQueue.main.async {
                        self.supportsTorch = supportsTorch
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.errorMessage = "Camera failed to start."
                    }
                    return
                }
            }

            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    private func setTorchOn(_ isOn: Bool) {
        guard let device = captureDevice, device.hasTorch, device.isTorchAvailable else {
            torchEnabled = false
            DispatchQueue.main.async {
                self.supportsTorch = false
                self.isTorchOn = false
            }
            return
        }

        var didLock = false
        do {
            try device.lockForConfiguration()
            didLock = true
            if isOn {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
            didLock = false
            torchEnabled = isOn
            DispatchQueue.main.async {
                self.supportsTorch = true
                self.isTorchOn = isOn
            }
        } catch {
            if didLock {
                device.unlockForConfiguration()
            }
            torchEnabled = false
            DispatchQueue.main.async {
                self.errorMessage = "Couldn’t toggle the light."
                self.isTorchOn = false
            }
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if error != nil {
            DispatchQueue.main.async {
                self.isCapturing = false
                self.errorMessage = "Couldn’t take that photo."
            }
            return
        }

        guard
            let data = photo.fileDataRepresentation(),
            let image = UIImage(data: data)
        else {
            DispatchQueue.main.async {
                self.isCapturing = false
                self.errorMessage = "Couldn’t read that photo."
            }
            return
        }

        DispatchQueue.main.async {
            self.isCapturing = false
            self.onCapture?(image)
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if error != nil {
            DispatchQueue.main.async {
                self.isCapturing = false
                self.errorMessage = "Couldn’t take that photo."
            }
        }
    }
}

private struct ScannerCornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let cornerLength = min(rect.width, rect.height) * 0.24
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + cornerLength))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + cornerLength, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - cornerLength, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cornerLength))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerLength))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - cornerLength, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + cornerLength, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cornerLength))

        return path
    }
}

struct CookbookPreppedCycle: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    var prepDateLabel: String? = nil
    var prepDateRangeLabel: String? = nil
    var themeIndex: Int = 0
    let recipes: [DiscoverRecipeCardData]
}

struct CookbookEditableRecipeCard: View {
    let recipe: DiscoverRecipeCardData
    let onRemove: () -> Void
    let onSelect: () -> Void

    var body: some View {
        RecipeLibraryVisualCard(
            recipe: recipe,
            topAction: DiscoverRemoteRecipeCardTopAction(
                systemName: "xmark",
                accessibilityLabel: "Remove from plan",
                showsBackground: true,
                symbolSize: 13,
                frameSize: 30,
                action: onRemove
            ),
            onSelect: onSelect
        )
    }
}

struct DarkBlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

struct CookbookCyclePage: View {
    let cycle: CookbookPreppedCycle
    @Binding var selectedTab: AppTab
    @ObservedObject var toastCenter: AppToastCenter

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var savedStore: SavedRecipesStore
    @EnvironmentObject private var firstRunGuide: FirstRunGuideCoordinator

    @Namespace private var recipeTransitionNamespace
    @State private var presentedRecipe: PresentedRecipeDetail?
    @State private var tracksLatestPrepCycle = false
    @State private var isRecipePickerPresented = false
    @State private var selectedPlanRecipeIDs: Set<String> = []
    @State private var isAddingToPlan = false
    @State private var planPickerError: String?
    @State private var isRenamePlanPresented = false
    @State private var planNameDraft = ""

    private let columns = [
        GridItem(.flexible(), spacing: 14, alignment: .top),
        GridItem(.flexible(), spacing: 14, alignment: .top)
    ]
    private let recipeGridSpacing: CGFloat = 24

    private var currentBatchID: UUID? {
        guard let batchID = UUID(uuidString: cycle.id),
              store.latestPlan?.batches?.contains(where: { $0.id == batchID }) == true else {
            return nil
        }
        return batchID
    }

    private var displayedPlannedRecipes: [PlannedRecipe] {
        if let currentBatchID,
           let batch = store.latestPlan?.batches?.first(where: { $0.id == currentBatchID }) {
            return batch.recipes
        }
        if tracksLatestPrepCycle || store.latestPlan?.id.uuidString == cycle.id {
            return store.latestPlan?.recipes ?? []
        }
        return []
    }

    private var isCurrentPrepCycle: Bool {
        currentBatchID != nil || tracksLatestPrepCycle || store.latestPlan?.id.uuidString == cycle.id
    }

    private var displayedRecipes: [DiscoverRecipeCardData] {
        if isCurrentPrepCycle {
            return displayedPlannedRecipes.map(DiscoverRecipeCardData.init(preppedRecipe:))
        }
        return cycle.recipes
    }

    private var recipesForDisplay: [DiscoverRecipeCardData] {
        displayedRecipes
    }

    private var planBatchIDForAdd: UUID? {
        if let currentBatchID {
            return currentBatchID
        }

        if tracksLatestPrepCycle || store.latestPlan?.id.uuidString == cycle.id {
            return store.activeBatch?.id ?? store.latestPlan?.activeBatchID
        }

        return nil
    }

    private var canAddToCurrentCycle: Bool {
        isCurrentPrepCycle && planBatchIDForAdd != nil
    }

    private var canAddRecipes: Bool {
        canAddToCurrentCycle && !savedStore.savedRecipes.isEmpty
    }

    private var displayedPlanTitle: String {
        guard let currentBatchID,
              let batch = store.latestPlan?.batches?.first(where: { $0.id == currentBatchID }) else {
            return cycle.title
        }
        return batch.name
    }

    private var renameTargetID: UUID? {
        if let currentBatchID {
            return currentBatchID
        }
        guard store.latestPlan?.id.uuidString == cycle.id else { return nil }
        return store.latestPlan?.id
    }

    private var canRenamePlan: Bool {
        renameTargetID != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OunjePalette.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 7) {
                                    Text(displayedPlanTitle)
                                        .biroHeaderFont(30)
                                        .foregroundStyle(OunjePalette.primaryText)
                                        .lineLimit(2)

                                    if canRenamePlan {
                                        Button {
                                            planNameDraft = displayedPlanTitle
                                            isRenamePlanPresented = true
                                        } label: {
                                            Image(systemName: "pencil")
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundStyle(OunjePalette.secondaryText)
                                                .frame(width: 28, height: 28)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Rename \(displayedPlanTitle)")
                                    }
                                }

                                Text("\(recipesForDisplay.count) \(recipesForDisplay.count == 1 ? "recipe" : "recipes") in this plan")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(OunjePalette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 8)

                            if canAddToCurrentCycle {
                                Button {
                                    startAddingRecipes()
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(OunjePalette.primaryText)
                                }
                                .buttonStyle(.plain)
                                .disabled(!canAddRecipes)
                                .opacity(canAddRecipes ? 1 : 0.62)
                            }
                        }

                        if recipesForDisplay.isEmpty {
                            RecipesEmptyState(
                                title: "No recipes in this plan",
                                detail: "Tap + to choose recipes from your collection.",
                                symbolName: "fork.knife.circle"
                            )
                        } else {
                            recipePagingSection
                        }
                    }
                    .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .allowsHitTesting(presentedRecipe == nil)

                if let presentedRecipe {
                    RecipeDetailExperienceView(
                        presentedRecipe: presentedRecipe,
                        onOpenCart: {
                            withAnimation(OunjeMotion.heroSpring) {
                                selectedTab = .cart
                                self.presentedRecipe = nil
                            }
                        },
                        toastCenter: toastCenter,
                        onDismiss: dismissPresentedRecipe,
                        transitionNamespace: recipeTransitionNamespace
                    )
                    .environmentObject(savedStore)
                    .background(OunjePalette.background.ignoresSafeArea())
                    .preferredColorScheme(.dark)
                    .transition(.opacity)
                    .zIndex(6)
                }

            }
            .scrollIndicators(.hidden)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationBarBackButtonHidden()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(OunjePalette.primaryText)
                    }
                }

            }
            .onAppear {
                if store.latestPlan?.id.uuidString == cycle.id {
                    tracksLatestPrepCycle = true
                }
            }
            .onChange(of: cycle.id) { _ in
                selectedPlanRecipeIDs = []
                isAddingToPlan = false
                planPickerError = nil
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isCurrentPrepCycle, !recipesForDisplay.isEmpty {
                Button {
                    if firstRunGuide.phase == .planShoppingList {
                        firstRunGuide.advance(to: .cartOverview)
                    }
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        selectedTab = .cart
                    }
                } label: {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)

                        HStack(spacing: 9) {
                            Image(systemName: "cart")
                            Text("View cart")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .black))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)

                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(OunjePalette.background)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(OunjePalette.softCream)
                    )
                    .firstRunGuideTarget(
                        .shoppingListButton,
                        enabled: firstRunGuide.phase == .planShoppingList
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.vertical, 10)
                .background(OunjePalette.background.opacity(0.96))
            }
        }
        .firstRunGuideHost()
        .overlay(alignment: .top) {
            if let toast = toastCenter.toast, presentedRecipe == nil {
                AppToastBanner(toast: toast, onTap: nil)
                    .id(toast.id)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(OunjeMotion.quickSpring, value: toastCenter.toast?.id)
        .sheet(isPresented: $isRecipePickerPresented) {
            PlanRecipePickerSheet(
                title: "Add recipes to \(displayedPlanTitle)",
                selectedRecipeIDs: $selectedPlanRecipeIDs,
                savedRecipes: savedStore.savedRecipes,
                isSyncingRecipes: savedStore.isSyncingRemote,
                isBusy: isAddingToPlan,
                pickerError: planPickerError,
                onAdd: {
                    Task {
                        await addSelectedRecipesToCurrentPlan()
                    }
                },
                onCancel: {
                    isRecipePickerPresented = false
                    selectedPlanRecipeIDs = []
                    planPickerError = nil
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isRenamePlanPresented) {
            RenameCookbookPlanSheet(
                name: $planNameDraft,
                onCancel: {
                    isRenamePlanPresented = false
                },
                onSave: renameCurrentPlan
            )
            .presentationDetents([.height(286)])
            .presentationDragIndicator(.hidden)
        }
    }

    @ViewBuilder
    private var recipePagingSection: some View {
        recipeGridPage(recipesForDisplay)
            .firstRunGuideTarget(
                .planRecipes,
                enabled: firstRunGuide.phase == .planOpened
            )
    }

    private func recipeGridPage(_ recipes: [DiscoverRecipeCardData]) -> some View {
        LazyVGrid(columns: columns, spacing: recipeGridSpacing) {
            ForEach(recipes) { recipe in
                CookbookEditableRecipeCard(
                    recipe: recipe,
                    onRemove: {
                        guard isCurrentPrepCycle else { return }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        let removedPlannedRecipe = displayedPlannedRecipes.first { $0.recipe.id == recipe.id }
                        toastCenter.show(
                            title: "Removed from plan",
                            subtitle: recipe.title,
                            systemImage: "minus.circle.fill",
                            thumbnailURLString: recipe.imageURLString,
                            destination: nil,
                            actionTitle: "Undo",
                            action: { [store, toastCenter] in
                                guard let removedPlannedRecipe else { return }
                                Task {
                                    await store.updateLatestPlan(
                                        with: removedPlannedRecipe.recipe,
                                        servings: removedPlannedRecipe.servings,
                                        targetBatchID: currentBatchID
                                    )
                                    await MainActor.run {
                                        toastCenter.dismiss()
                                    }
                                }
                            }
                        )
                        Task {
                            await Task.yield()
                            if let currentBatchID {
                                await store.removeRecipe(recipeID: recipe.id, fromPrepBatch: currentBatchID)
                            } else {
                                await store.removeRecipeFromLatestPlan(recipeID: recipe.id)
                            }
                        }
                    },
                    onSelect: {
                        presentRecipeDetail(for: recipe)
                    }
                )
            }
        }
    }

    private func presentRecipeDetail(for recipe: DiscoverRecipeCardData) {
        withAnimation(OunjeMotion.heroSpring) {
            presentedRecipe = PresentedRecipeDetail(recipeCard: recipe)
        }
    }

    private func dismissPresentedRecipe() {
        withAnimation(OunjeMotion.heroSpring) {
            presentedRecipe = nil
        }
    }

    private func startAddingRecipes() {
        guard canAddToCurrentCycle else {
            toastCenter.show(
                title: "Unable to add recipes",
                subtitle: "Open this plan from the current cookbook first.",
                systemImage: "exclamationmark.circle.fill"
            )
            return
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        selectedPlanRecipeIDs = []
        planPickerError = nil
        isRecipePickerPresented = true
    }

    private func addSelectedRecipesToCurrentPlan() async {
        guard let batchID = planBatchIDForAdd,
              !selectedPlanRecipeIDs.isEmpty,
              !isAddingToPlan else {
            return
        }

        isAddingToPlan = true
        planPickerError = nil

        let accessToken = await store.freshUserDataSession()?.accessToken
        let selectedRecipes = savedStore.savedRecipes.filter { selectedPlanRecipeIDs.contains($0.id) }
        var failedRecipeIDs = Set<String>()

        for recipe in selectedRecipes {
            do {
                let detail = try await RecipeDetailService.shared.fetchRecipeDetail(
                    id: recipe.id,
                    accessToken: accessToken
                )
                let plannedRecipe = recipePlanModel(
                    from: detail,
                    targetServings: detail.displayServings,
                    fallbackRecipe: nil
                )
                await store.updateLatestPlan(
                    with: plannedRecipe,
                    servings: plannedRecipe.servings,
                    targetBatchID: batchID
                )
            } catch {
                failedRecipeIDs.insert(recipe.id)
            }
        }

        await MainActor.run {
            isAddingToPlan = false

            if failedRecipeIDs.isEmpty {
                isRecipePickerPresented = false
                selectedPlanRecipeIDs = []
                planPickerError = nil
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                toastCenter.show(
                    title: "Added to plan",
                    subtitle: "\(selectedRecipes.count) recipes added to \(displayedPlanTitle).",
                    systemImage: "checkmark.circle.fill"
                )
            } else {
                selectedPlanRecipeIDs = failedRecipeIDs
                let noun = failedRecipeIDs.count == 1 ? "recipe" : "recipes"
                planPickerError = "Couldn’t add \(failedRecipeIDs.count) \(noun). Tap Add to retry."
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func renameCurrentPlan() {
        guard let renameTargetID else { return }
        let trimmedName = planNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        store.renamePrepBatch(id: renameTargetID, to: trimmedName)
        isRenamePlanPresented = false
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        toastCenter.show(
            title: "Plan renamed",
            subtitle: trimmedName,
            systemImage: "checkmark.circle.fill"
        )
    }

}

private struct RenameCookbookPlanSheet: View {
    @Binding var name: String
    let onCancel: () -> Void
    let onSave: () -> Void

    @FocusState private var isNameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            OunjePalette.background
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                OunjeSheetHeader(
                    title: "Rename plan",
                    closeAccessibilityLabel: "Cancel renaming plan",
                    onClose: onCancel
                )

                TextField("Plan name", text: $name)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(OunjePalette.primaryText)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($isNameFocused)
                    .onSubmit {
                        guard !trimmedName.isEmpty else { return }
                        onSave()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: OunjeLayout.controlCornerRadius, style: .continuous)
                            .fill(OunjePalette.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: OunjeLayout.controlCornerRadius, style: .continuous)
                                    .stroke(OunjePalette.stroke, lineWidth: 1)
                            )
                    )

                Button(action: onSave) {
                    Text("Save name")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(OunjePalette.background)
                        .frame(maxWidth: .infinity)
                        .frame(height: OunjeLayout.primaryButtonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: OunjeLayout.controlCornerRadius, style: .continuous)
                                .fill(OunjePalette.softCream)
                        )
                }
                .buttonStyle(OunjeCardPressButtonStyle())
                .disabled(trimmedName.isEmpty)
                .opacity(trimmedName.isEmpty ? 0.42 : 1)
            }
            .padding(.horizontal, OunjeLayout.sheetHorizontalPadding)
            .padding(.top, OunjeLayout.sheetTopPadding)
            .padding(.bottom, OunjeLayout.sheetBottomPadding)
        }
        .ounjeSheetSurface()
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                isNameFocused = true
            }
        }
    }
}

private struct PlanRecipePickerSheet: View {
    let title: String
    @Binding var selectedRecipeIDs: Set<String>
    let savedRecipes: [DiscoverRecipeCardData]
    let isSyncingRecipes: Bool
    let isBusy: Bool
    let pickerError: String?
    let onAdd: () -> Void
    let onCancel: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 18, alignment: .top),
        GridItem(.flexible(), spacing: 18, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 0) {
            OunjeSheetHeader(
                title: title,
                titleStyle: .standard,
                closeAccessibilityLabel: "Cancel adding recipes",
                onClose: onCancel
            )
            .padding(16)

            if !savedRecipes.isEmpty {
                HStack(spacing: 12) {
                    Text("\(selectedRecipeIDs.count) selected")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText)

                    Spacer(minLength: 0)

                    Button(action: onAdd) {
                    if isBusy {
                        ProgressView()
                            .tint(OunjePalette.background)
                    } else {
                        Text("Add")
                    }
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(OunjePalette.background)
                .frame(width: 56, height: 30)
                .background(
                    Capsule(style: .continuous)
                        .fill(OunjePalette.softCream)
                )
                .disabled(isBusy || selectedRecipeIDs.isEmpty)
                .opacity((selectedRecipeIDs.isEmpty || isBusy) ? 0.45 : 1)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            if isSyncingRecipes {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(0..<4, id: \.self) { _ in
                        DiscoverRecipeCardLoadingPlaceholder()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            } else if savedRecipes.isEmpty {
                Text("No saved recipes to add yet.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(savedRecipes) { recipe in
                            RecipeLibraryVisualCard(
                                recipe: recipe,
                                selectionState: selectedRecipeIDs.contains(recipe.id),
                                selectionAction: {
                                    toggle(recipe.id)
                                },
                                onSelect: {
                                    toggle(recipe.id)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
            }

            if let pickerError {
                Text(pickerError)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .background(OunjePalette.background)
    }

    private func toggle(_ recipeID: String) {
        guard !isBusy else { return }
        if selectedRecipeIDs.contains(recipeID) {
            selectedRecipeIDs.remove(recipeID)
        } else {
            selectedRecipeIDs.insert(recipeID)
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

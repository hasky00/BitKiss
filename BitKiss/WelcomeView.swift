import SwiftUI

/// First-run flow: what BitKiss is, the 12 recovery words, one habit.
/// Shown once; the words can always be seen again under Advanced.
struct WelcomeView: View {
    let manager: NodeManager
    let onDone: () -> Void

    @AppStorage("wordsBackedUp") private var wordsBackedUp = false
    @State private var page = 0
    @State private var confirmed = false

    var body: some View {
        ZStack {
            BK.plum.ignoresSafeArea()
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    intro.tag(0)
                    words.tag(1)
                    habit.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: page)

                HStack(spacing: 8) {
                    ForEach(0..<3) { i in
                        Capsule()
                            .fill(i == page ? BK.pink : Color.white.opacity(0.2))
                            .frame(width: i == page ? 22 : 8, height: 8)
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .foregroundStyle(.white)
        .interactiveDismissDisabled()
    }

    // MARK: Page 1

    private var intro: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "bolt.fill")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(BK.orange)
            Text("BitKiss")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundStyle(BK.pink)
            Text("A Lightning wallet that is really yours.")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 14) {
                point("key.fill", "Your keys are made on this phone and never leave it.")
                point("bolt.fill", "Your own Lightning node runs inside the app.")
                point("person.slash.fill", "Nobody in the middle. Not even Hasky Labs.")
            }
            .padding(.horizontal, 8)
            Spacer()
            primary("Create my wallet") { page = 1 }
        }
        .padding(28)
    }

    // MARK: Page 2

    private var words: some View {
        VStack(spacing: 18) {
            Text("Your 12 recovery words")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(BK.pink)
                .padding(.top, 20)
            Text("Write them down on paper, in order, and keep them somewhere safe. They are the only way to get your sats back if you lose this phone.")
                .font(.footnote)
                .foregroundStyle(BK.muted)
                .multilineTextAlignment(.center)

            if manager.mnemonic.isEmpty {
                Spacer()
                ProgressView().tint(BK.pink)
                Text("Creating your wallet...").font(.footnote).foregroundStyle(BK.muted)
                Spacer()
            } else {
                let list = manager.mnemonic.split(separator: " ").map(String.init)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Array(list.enumerated()), id: \.offset) { i, w in
                        HStack(spacing: 10) {
                            Text("\(i + 1)")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(BK.muted)
                                .frame(width: 22, alignment: .trailing)
                            Text(w)
                                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                            Spacer()
                        }
                        .padding(.vertical, 10).padding(.horizontal, 12)
                        .background(BK.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                Text("Never share these words. Anyone who has them has your sats.")
                    .font(.caption)
                    .foregroundStyle(BK.orange)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 8)
                Toggle(isOn: $confirmed) {
                    Text("I have written them down").font(.subheadline.weight(.semibold))
                }
                .tint(BK.pink)
                .padding(.horizontal, 4)
            }

            primary("Continue") {
                wordsBackedUp = confirmed
                page = 2
            }
            .disabled(manager.mnemonic.isEmpty)
            if !manager.mnemonic.isEmpty && !confirmed {
                Button("Skip for now, remind me later") {
                    wordsBackedUp = false
                    page = 2
                }
                .font(.footnote)
                .foregroundStyle(BK.muted)
            }
        }
        .padding(24)
    }

    // MARK: Page 3

    private var habit: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "clock.badge.checkmark.fill")
                .font(.system(size: 56))
                .foregroundStyle(BK.green)
            Text("One small habit")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(BK.pink)
            Text("Open BitKiss every few days and let it sync for a moment. Your node on this phone keeps an eye on the network for you, and it can only do that while the app is open.")
                .font(.body)
                .foregroundStyle(BK.muted)
                .multilineTextAlignment(.center)
            Text("Travel, airplane mode, a phone switched off: all fine. Just don't forget it for weeks.")
                .font(.footnote)
                .foregroundStyle(BK.muted)
                .multilineTextAlignment(.center)
            Spacer()
            primary("Let's go") { onDone() }
        }
        .padding(28)
    }

    // MARK: Bits

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(BK.orange)
                .frame(width: 24)
            Text(text).font(.subheadline)
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity).frame(height: 54)
        }
        .buttonStyle(.borderedProminent)
        .tint(BK.pink)
    }
}

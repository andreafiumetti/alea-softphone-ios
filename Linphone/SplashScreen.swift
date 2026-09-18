/*
 * Copyright (c) 2010-2023 Belledonne Communications SARL.
 * ALEA Softphone branding overlay
 */

import SwiftUI

struct SplashScreen: View {
	var showSpinner: Bool = false

	var body: some View {
		ZStack {
			Color(hex: "#0A0E17")
				.ignoresSafeArea()

			Image("alea-splash")
				.resizable()
				.renderingMode(.original)
				.aspectRatio(contentMode: .fit)
				.frame(width: 160, height: 160)

			if showSpinner {
				PopupLoadingView()
					.background(.black.opacity(0.65))
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.ignoresSafeArea(.all)
	}
}

#Preview {
	SplashScreen()
}

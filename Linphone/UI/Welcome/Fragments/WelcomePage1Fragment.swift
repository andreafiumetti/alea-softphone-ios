/*
 * Copyright (c) 2010-2023 Belledonne Communications SARL.
 * ALEA Softphone — welcome page 1 parity with Android welcome_page_1.xml
 */

import Foundation
import SwiftUI

struct WelcomePage1Fragment: View {
	
	var body: some View {
		VStack {
			Spacer()
			VStack {
				Image("alea-mark-circle")
					.renderingMode(.original)
					.resizable()
					.aspectRatio(contentMode: .fit)
					.frame(width: 100, height: 100)
				Text(Bundle.main.displayName)
					.welcome_text_style_gray_800(styleSize: 30)
					.padding(.bottom, 20)
				Text("welcome_page_1_message")
					.welcome_text_style_gray(styleSize: 15)
					.multilineTextAlignment(.center)
				
			}
			.padding(.horizontal)
			.padding(.bottom, 60)
			
			Spacer()
		}
		.frame(maxWidth: .infinity)
		.padding(.horizontal, 20)
	}
}

#Preview {
	WelcomePage1Fragment()
}

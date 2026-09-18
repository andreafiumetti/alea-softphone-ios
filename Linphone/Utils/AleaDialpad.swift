/*
 * ALEA Softphone iOS — dialpad tab
 * Opens ContentView StartCall overlay; no permanent spinner.
 */

import SwiftUI

struct AleaDialpadFragment: View {
	@Binding var showingDialer: Bool
	@Binding var isShowStartCallFragment: Bool

	var body: some View {
		Color.white
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.onAppear {
				showingDialer = true
				isShowStartCallFragment = true
			}
	}
}

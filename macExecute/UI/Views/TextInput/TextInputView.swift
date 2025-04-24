//
//  TextInputView.swift
//  macExecute
//
//  Created by Stossy11 on 24/04/2025.
//

import SwiftUI

struct TextInputView: View {
    @State private var inputText = ""

    let runner = DylibMainRunner.shared

    var body: some View {
        VStack(spacing: 16) {
            TextField("Type here...", text: $inputText)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()
                .onSubmit {
                    runner.sendInput(inputText + "\n")
                    inputText = ""
                }
        }
        .padding()
    }
}

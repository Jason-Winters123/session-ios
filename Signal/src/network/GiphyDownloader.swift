//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation
import SessionServiceKit

@objc
public class GiphyDownloader: ProxiedContentDownloader {

    // MARK: - Properties

    @objc
    public static let giphyDownloader = GiphyDownloader(downloadFolderName: "GIFs")
}

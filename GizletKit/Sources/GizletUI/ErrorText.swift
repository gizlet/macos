import GizletCore
import Foundation

extension Localizer {
    /// An error as the interface shows it, in its language. Details that come
    /// from a package, a server or the system (file names, HTTP statuses) are
    /// kept as they are, after a translated explanation.
    public func describe(_ error: Error) -> String {
        switch error {
        case let error as PackageError:
            switch error {
            case .invalid(let detail): return self("Not a valid package: \(detail)", "不是有效的软件包：\(detail)")
            case .unsupported(let detail): return self(detail, "这台 Mac 无法运行它：\(detail)")
            case .running(let id): return self("\(id) is running; quit it first", "\(id) 正在运行，请先退出")
            case .notInstalled(let id): return self("\(id) is not installed", "\(id) 没有安装")
            case .io(let detail): return self(detail, "文件操作失败：\(detail)")
            }
        case let error as RunningApps.Refusal:
            switch error {
            case .running(let id): return self("\(id) is running; quit it first", "\(id) 正在运行，请先退出")
            case .busy(let id): return self("\(id) is being updated; try again when it is done", "\(id) 正在更新，完成后再试")
            }
        case let error as StoreInstallError:
            switch error {
            case .otherSource(let id, let from?):
                return self("\(id) was installed from \(from); uninstall it first to install this one", "\(id) 是从 \(from) 安装的，请先卸载再安装这一个")
            case .otherSource(let id, nil):
                return self("\(id) was installed from a file; uninstall it first to install it from the Store", "\(id) 是从文件安装的，请先卸载再从商店安装")
            case .repositoryChanged(let id):
                return self("The repository \(id) came from was replaced by another; uninstall it first", "\(id) 的来源仓库已被另一个仓库取代，请先卸载")
            case .changedWhileWaiting(let id):
                return self("\(id) changed while waiting to update; check for updates again", "\(id) 在等待更新时发生了变化，请重新检查更新")
            case .notReady: return self("The package is still being checked; try again in a minute", "软件包仍在检查中，请稍后再试")
            case .badPackage: return self("The Gizlet Store sent an invalid package", "Gizlet 商店返回了无效的软件包")
            }
        case let error as StoreAPIError:
            if error == .offline { return self("The Gizlet Store cannot be reached; check the connection", "无法连接 Gizlet 商店，请检查网络") }
            return self(error.message, "Gizlet 商店：\(error.message)")
        case let error as DownloadError:
            switch error {
            case .http(let status): return self("The download failed (HTTP \(status))", "下载失败（HTTP \(status)）")
            case .sizeMismatch: return self("The download did not match its size; try again", "下载的文件大小不对，请重试")
            case .checksumMismatch: return self("The download is damaged (SHA-256 mismatch); try again", "下载的文件已损坏（SHA-256 不一致），请重试")
            case .tooLarge: return self("The download is larger than expected", "下载的文件比预期大")
            case .offline: return self("The download stopped; check the connection and try again", "下载中断，请检查网络后重试")
            }
        case let error as UpdateError:
            switch error {
            case .feed(let detail): return self("Cannot check for updates: \(detail)", "无法检查更新：\(detail)")
            case .noRelease: return self("No version is published yet", "还没有发布任何版本")
            case .notNewer: return self("This version is up to date", "已是最新版本")
            case .incompatible(let minimum): return self("The new version needs macOS \(minimum) or later", "新版本需要 macOS \(minimum) 或更高版本")
            case .notInstallable(let detail): return self(detail, "无法安装更新：\(detail)")
            case .verification(let detail): return self("The update failed verification and was not installed: \(detail)", "更新未通过校验，没有安装：\(detail)")
            }
        case let error as FlashError:
            switch error {
            case .release(let detail): return self("Cannot use the Gizlet OS release: \(detail)", "无法使用这个 Gizlet OS 版本：\(detail)")
            case .cardChanged:
                return self("The card changed since it was confirmed; nothing was written. Choose the card and confirm again.",
                            "确认之后卡片发生了变化，没有写入任何内容。请重新选择并确认卡片。")
            case .cancelled: return self("Cancelled", "已取消")
            case .authorization: return self("Administrator authorization was not given; nothing was written", "没有获得管理员授权，没有写入任何内容")
            case .image(let detail), .disk(let detail), .write(let detail), .verify(let detail): return self(detail, "刷机失败：\(detail)")
            }
        case let error as ProfileError:
            switch error {
            case .badName(let problem): return self(problem, "名称不可用：\(problem)")
            case .taken(let name): return self("A profile is already called \(name)", "已有名为 \(name) 的 Profile")
            case .notFound(let key): return self("No profile \(key)", "没有 Profile \(key)")
            case .isCurrent: return self("The profile in use cannot be deleted; switch to another one first", "不能删除正在使用的 Profile，请先切换到其他 Profile")
            case .io(let detail): return self(detail, "文件操作失败：\(detail)")
            }
        case let error as SignatureError:
            return self(error.localizedDescription, "签名校验失败：\(error.localizedDescription)")
        default:
            return error.localizedDescription
        }
    }
}

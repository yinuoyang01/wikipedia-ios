
import UIKit

class ReplyButtonFooterView: SizeThatFitsReusableView {
    private let replyButton = ActionButton(frame: .zero)
    private let dividerView = UIView(frame: .zero)
    
    override func sizeThatFits(_ size: CGSize, apply: Bool) -> CGSize {
        let semanticContentAttribute: UISemanticContentAttribute = traitCollection.layoutDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        
        let adjustedMargins = UIEdgeInsets(top: layoutMargins.top + 25, left: layoutMargins.left + 5, bottom: layoutMargins.bottom + 75, right: layoutMargins.right + 5)
        let maximumWidth = size.width - adjustedMargins.left - adjustedMargins.right
        let dividerHeight = CGFloat(1)
        let buttonOrigin = CGPoint(x: adjustedMargins.left, y: adjustedMargins.top + dividerHeight + 35)
        
        var replyButtonFrame = replyButton.wmf_preferredFrame(at: buttonOrigin, maximumSize: CGSize(width: maximumWidth, height: UIView.noIntrinsicMetric), minimumSize: NoIntrinsicSize, alignedBy:semanticContentAttribute, apply: apply)
        
        //update frame to be centered
        if (apply) {
            replyButtonFrame.origin = CGPoint(x: (size.width / 2) - (replyButtonFrame.width / 2), y: replyButtonFrame.origin.y)
            replyButton.frame = replyButtonFrame
            dividerView.frame = CGRect(x: 0, y: adjustedMargins.top, width: size.width, height: dividerHeight)
        }
        
        
        let finalHeight = adjustedMargins.top + dividerHeight + replyButtonFrame.height + adjustedMargins.bottom
        
        return CGSize(width: size.width, height: finalHeight)
    }
    
    override func updateFonts(with traitCollection: UITraitCollection) {
        replyButton.updateFonts(with: traitCollection)
    }
 
    override func setup() {
        
        replyButton.setTitle(WMFLocalizedString("talk-pages-reply-button-title", value: "Reply to this discussion", comment: "Text displayed in a reply button for replying to a talk page discussion thread."), for: .normal)
        addSubview(replyButton)
        addSubview(dividerView)
        super.setup()
    }
}

extension ReplyButtonFooterView: Themeable {
    func apply(theme: Theme) {
        backgroundColor = theme.colors.paperBackground
        dividerView.backgroundColor = theme.colors.border
        replyButton.apply(theme: theme)
        
    }
}


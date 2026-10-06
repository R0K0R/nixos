#include "NaturalRender.h"

#include <QFontMetricsF>
#include <QPainterPath>
#include <algorithm>
#include <cmath>

namespace fx {

namespace {
constexpr qreal kShrink = 0.72;   // each nesting level shrinks the glyphs
constexpr qreal kMinPixel = 9.0;
constexpr qreal kFracGap = 2.0;
constexpr qreal kFracPad = 2.5;
} // namespace

NaturalRender::NaturalRender(const QFont &baseFont, qreal basePixelSize)
    : m_base(baseFont), m_basePixelSize(basePixelSize)
{
}

QFont NaturalRender::fontFor(int level) const
{
    QFont f = m_base;
    const qreal px = std::max(kMinPixel, m_basePixelSize * std::pow(kShrink, level));
    f.setPixelSize(static_cast<int>(std::lround(px)));
    return f;
}

QFontMetricsF NaturalRender::metricsFor(int level) const
{
    return QFontMetricsF(fontFor(level));
}

// ---------------------------------------------------------------------------
// Measuring
// ---------------------------------------------------------------------------

Box NaturalRender::measureAtom(const QString &code, int level) const
{
    const QFontMetricsF fm = metricsFor(level);
    const QString glyph = atomGlyph(code);
    Box b;
    b.width = fm.horizontalAdvance(glyph);
    b.ascent = fm.ascent();
    b.descent = fm.descent();
    // Operators breathe a little, the way the LCD spaces them.
    if (code == QLatin1String("+") || code == QLatin1String("-") || code == QLatin1String("*")
        || code == QLatin1String("/"))
        b.width += fm.horizontalAdvance(QLatin1Char(' ')) * 0.6;
    return b;
}

Box NaturalRender::measureRow(const Node *row, int level) const
{
    const QFontMetricsF fm = metricsFor(level);
    Box b;
    b.ascent = fm.ascent();
    b.descent = fm.descent();
    if (!row || row->childCount() == 0) {
        b.width = placeholderWidth(fm.height());
        return b;
    }
    for (Node *child : row->children()) {
        const Box cb = measure(child, level);
        b.width += cb.width;
        b.ascent = std::max(b.ascent, cb.ascent);
        b.descent = std::max(b.descent, cb.descent);
    }
    return b;
}

Box NaturalRender::measure(const Node *n, int level) const
{
    if (!n)
        return Box();
    if (n->isRow())
        return measureRow(n, level);
    if (n->isAtom())
        return measureAtom(n->code(), level);

    const QFontMetricsF fm = metricsFor(level);
    const qreal em = fm.height();
    Box b;

    switch (n->kind()) {
    case NodeKind::Frac:
    case NodeKind::MixedFrac: {
        const int first = (n->kind() == NodeKind::MixedFrac) ? 1 : 0;
        const Box num = measureRow(n->arg(first), level + 1);
        const Box den = measureRow(n->arg(first + 1), level + 1);
        qreal wholeW = 0.0;
        if (n->kind() == NodeKind::MixedFrac) {
            const Box whole = measureRow(n->arg(0), level);
            wholeW = whole.width + 1.0;
        }
        b.width = wholeW + std::max(num.width, den.width) + 2 * kFracPad;
        b.ascent = num.height() + kFracGap + fm.ascent() * 0.30;
        b.descent = den.height() + kFracGap - fm.ascent() * 0.30 + fm.descent() * 0.4;
        break;
    }
    case NodeKind::Power: {
        const Box exp = measureRow(n->arg(0), level + 1);
        b.width = exp.width + 1.0;
        b.ascent = fm.ascent() * 0.55 + exp.height();
        b.descent = 0.0;
        break;
    }
    case NodeKind::Sqrt: {
        const Box rad = measureRow(n->arg(0), level);
        b.width = em * 0.62 + rad.width + 3.0;
        b.ascent = rad.ascent + 3.5;
        b.descent = rad.descent;
        break;
    }
    case NodeKind::Root: {
        const Box idx = measureRow(n->arg(0), level + 2);
        const Box rad = measureRow(n->arg(1), level);
        b.width = std::max(em * 0.62, idx.width + em * 0.25) + rad.width + 3.0;
        b.ascent = std::max(rad.ascent + 3.5, rad.ascent + idx.height() * 0.5);
        b.descent = rad.descent;
        break;
    }
    case NodeKind::LogBase: {
        const Box base = measureRow(n->arg(0), level + 1);
        const Box arg = measureRow(n->arg(1), level);
        b.width = fm.horizontalAdvance(QStringLiteral("log")) + base.width
                + fm.horizontalAdvance(QStringLiteral("()")) + arg.width;
        b.ascent = std::max(fm.ascent(), arg.ascent);
        b.descent = std::max(arg.descent, base.height() * 0.5 + fm.descent());
        break;
    }
    case NodeKind::Abs: {
        const Box arg = measureRow(n->arg(0), level);
        b.width = arg.width + 8.0;
        b.ascent = arg.ascent + 1.0;
        b.descent = arg.descent + 1.0;
        break;
    }
    case NodeKind::Sum:
    case NodeKind::Product: {
        const Box body = measureRow(n->arg(0), level);
        const Box from = measureRow(n->arg(1), level + 2);
        const Box to = measureRow(n->arg(2), level + 2);
        const qreal sym = em * 0.9;
        b.width = std::max(sym, std::max(from.width, to.width)) + 2.0 + body.width;
        b.ascent = std::max(body.ascent, sym * 0.6 + to.height());
        b.descent = std::max(body.descent, sym * 0.4 + from.height());
        break;
    }
    case NodeKind::Integral: {
        const Box body = measureRow(n->arg(0), level);
        const Box lo = measureRow(n->arg(1), level + 2);
        const Box hi = measureRow(n->arg(2), level + 2);
        const qreal sym = em * 0.5;
        b.width = sym + std::max(lo.width, hi.width) + 3.0 + body.width
                + metricsFor(level).horizontalAdvance(QStringLiteral("dx"));
        b.ascent = std::max(body.ascent, em * 0.55 + hi.height());
        b.descent = std::max(body.descent, em * 0.45 + lo.height());
        break;
    }
    case NodeKind::Derivative: {
        const Box body = measureRow(n->arg(0), level);
        const Box at = measureRow(n->arg(1), level + 1);
        const qreal head = metricsFor(level + 1).horizontalAdvance(QStringLiteral("d/dx"));
        b.width = head + 2.0 + body.width + at.width + 8.0;
        b.ascent = std::max(body.ascent, em * 0.8);
        b.descent = std::max(body.descent, em * 0.5);
        break;
    }
    case NodeKind::Recurring: {
        const Box inner = measureRow(n->arg(0), level);
        b = inner;
        b.ascent += 2.5;
        break;
    }
    default:
        break;
    }
    return b;
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

void NaturalRender::drawPlaceholder(QPainter *p, qreal x, qreal baseline, int level) const
{
    const QFontMetricsF fm = metricsFor(level);
    const qreal s = placeholderWidth(fm.height());
    const QRectF r(x + 1.0, baseline - fm.ascent() * 0.78, s - 2.0, s - 2.0);
    p->save();
    QPen pen = p->pen();
    pen.setWidthF(1.0);
    pen.setStyle(Qt::DotLine);
    p->setPen(pen);
    p->setBrush(Qt::NoBrush);
    p->drawRect(r);
    p->restore();
}

void NaturalRender::drawAtom(QPainter *p, const QString &code, qreal x, qreal baseline,
                             int level) const
{
    p->setFont(fontFor(level));
    p->drawText(QPointF(x, baseline), atomGlyph(code));
}

void NaturalRender::drawRow(QPainter *p, const Node *row, qreal x, qreal baseline, int level) const
{
    const QFontMetricsF fm = metricsFor(level);

    auto markCursor = [&](qreal cx) {
        m_cursorRect = QRectF(cx, baseline - fm.ascent(), 1.6, fm.height());
    };

    if (!row || row->childCount() == 0) {
        drawPlaceholder(p, x, baseline, level);
        if (m_showCursor && row == m_cursorRow)
            markCursor(x);
        return;
    }

    qreal cx = x;
    const auto kids = row->children();
    for (int i = 0; i < kids.size(); ++i) {
        if (m_showCursor && row == m_cursorRow && i == m_cursorIndex)
            markCursor(cx);
        const Box cb = measure(kids.at(i), level);
        draw(p, kids.at(i), cx, baseline, level);
        cx += cb.width;
    }
    if (m_showCursor && row == m_cursorRow && m_cursorIndex >= kids.size())
        markCursor(cx);
}

void NaturalRender::draw(QPainter *p, const Node *n, qreal x, qreal baseline, int level) const
{
    if (!n)
        return;
    if (n->isRow()) {
        drawRow(p, n, x, baseline, level);
        return;
    }
    if (n->isAtom()) {
        const QFontMetricsF fm = metricsFor(level);
        qreal tx = x;
        const QString &c = n->code();
        if (c == QLatin1String("+") || c == QLatin1String("-") || c == QLatin1String("*")
            || c == QLatin1String("/"))
            tx += fm.horizontalAdvance(QLatin1Char(' ')) * 0.3;
        drawAtom(p, c, tx, baseline, level);
        return;
    }

    const QFontMetricsF fm = metricsFor(level);
    const qreal em = fm.height();
    QPen pen = p->pen();
    pen.setWidthF(std::max(1.0, em / 16.0));

    switch (n->kind()) {
    case NodeKind::Frac:
    case NodeKind::MixedFrac: {
        const int first = (n->kind() == NodeKind::MixedFrac) ? 1 : 0;
        qreal cx = x;
        if (n->kind() == NodeKind::MixedFrac) {
            const Box whole = measureRow(n->arg(0), level);
            drawRow(p, n->arg(0), cx, baseline, level);
            cx += whole.width + 1.0;
        }
        const Box num = measureRow(n->arg(first), level + 1);
        const Box den = measureRow(n->arg(first + 1), level + 1);
        const qreal barY = baseline - fm.ascent() * 0.30;
        const qreal inner = std::max(num.width, den.width);
        const qreal barW = inner + 2 * kFracPad;

        drawRow(p, n->arg(first), cx + kFracPad + (inner - num.width) / 2.0,
                barY - kFracGap - num.descent, level + 1);
        drawRow(p, n->arg(first + 1), cx + kFracPad + (inner - den.width) / 2.0,
                barY + kFracGap + den.ascent, level + 1);

        p->save();
        p->setPen(pen);
        p->drawLine(QPointF(cx, barY), QPointF(cx + barW, barY));
        p->restore();
        break;
    }
    case NodeKind::Power: {
        const Box exp = measureRow(n->arg(0), level + 1);
        drawRow(p, n->arg(0), x + 1.0, baseline - fm.ascent() * 0.55 - exp.descent, level + 1);
        break;
    }
    case NodeKind::Sqrt:
    case NodeKind::Root: {
        const bool nth = n->kind() == NodeKind::Root;
        const int radArg = nth ? 1 : 0;
        const Box rad = measureRow(n->arg(radArg), level);
        qreal hookW = em * 0.62;
        if (nth) {
            const Box idx = measureRow(n->arg(0), level + 2);
            hookW = std::max(hookW, idx.width + em * 0.25);
            drawRow(p, n->arg(0), x, baseline - rad.ascent - 1.0, level + 2);
        }
        const qreal top = baseline - rad.ascent - 3.5;
        const qreal bottom = baseline + rad.descent;
        p->save();
        p->setPen(pen);
        QPainterPath path;
        path.moveTo(x + hookW * 0.10, baseline - rad.ascent * 0.45);
        path.lineTo(x + hookW * 0.38, baseline - rad.ascent * 0.28);
        path.lineTo(x + hookW * 0.62, bottom);
        path.lineTo(x + hookW * 0.92, top);
        path.lineTo(x + hookW + rad.width + 2.0, top);
        p->drawPath(path);
        p->restore();
        drawRow(p, n->arg(radArg), x + hookW + 1.0, baseline, level);
        break;
    }
    case NodeKind::LogBase: {
        const Box base = measureRow(n->arg(0), level + 1);
        p->setFont(fontFor(level));
        p->drawText(QPointF(x, baseline), QStringLiteral("log"));
        qreal cx = x + fm.horizontalAdvance(QStringLiteral("log"));
        drawRow(p, n->arg(0), cx, baseline + base.ascent * 0.42, level + 1);
        cx += base.width;
        p->setFont(fontFor(level));
        p->drawText(QPointF(cx, baseline), QStringLiteral("("));
        cx += fm.horizontalAdvance(QStringLiteral("("));
        const Box arg = measureRow(n->arg(1), level);
        drawRow(p, n->arg(1), cx, baseline, level);
        cx += arg.width;
        p->setFont(fontFor(level));
        p->drawText(QPointF(cx, baseline), QStringLiteral(")"));
        break;
    }
    case NodeKind::Abs: {
        const Box arg = measureRow(n->arg(0), level);
        p->save();
        p->setPen(pen);
        p->drawLine(QPointF(x + 2.0, baseline - arg.ascent), QPointF(x + 2.0, baseline + arg.descent));
        p->drawLine(QPointF(x + arg.width + 6.0, baseline - arg.ascent),
                    QPointF(x + arg.width + 6.0, baseline + arg.descent));
        p->restore();
        drawRow(p, n->arg(0), x + 4.0, baseline, level);
        break;
    }
    case NodeKind::Sum:
    case NodeKind::Product: {
        const Box from = measureRow(n->arg(1), level + 2);
        const Box to = measureRow(n->arg(2), level + 2);
        const qreal sym = em * 0.9;
        const qreal colW = std::max(sym, std::max(from.width, to.width));
        QFont big = fontFor(level);
        big.setPixelSize(static_cast<int>(std::lround(sym)));
        p->setFont(big);
        const QString glyph = (n->kind() == NodeKind::Sum) ? QStringLiteral("Σ")
                                                           : QStringLiteral("Π");
        const QFontMetricsF bfm(big);
        p->drawText(QPointF(x + (colW - bfm.horizontalAdvance(glyph)) / 2.0, baseline + em * 0.18),
                    glyph);
        drawRow(p, n->arg(2), x + (colW - to.width) / 2.0, baseline - sym * 0.6 - to.descent,
                level + 2);
        drawRow(p, n->arg(1), x + (colW - from.width) / 2.0, baseline + sym * 0.4 + from.ascent,
                level + 2);
        drawRow(p, n->arg(0), x + colW + 2.0, baseline, level);
        break;
    }
    case NodeKind::Integral: {
        const Box lo = measureRow(n->arg(1), level + 2);
        const Box hi = measureRow(n->arg(2), level + 2);
        const qreal sym = em * 0.5;
        QFont big = fontFor(level);
        big.setPixelSize(static_cast<int>(std::lround(em * 1.5)));
        p->setFont(big);
        p->drawText(QPointF(x, baseline + em * 0.25), QStringLiteral("∫"));
        const qreal colX = x + sym;
        drawRow(p, n->arg(2), colX, baseline - em * 0.55 - hi.descent, level + 2);
        drawRow(p, n->arg(1), colX, baseline + em * 0.45 + lo.ascent, level + 2);
        const qreal bodyX = colX + std::max(lo.width, hi.width) + 3.0;
        const Box body = measureRow(n->arg(0), level);
        drawRow(p, n->arg(0), bodyX, baseline, level);
        p->setFont(fontFor(level));
        p->drawText(QPointF(bodyX + body.width, baseline), QStringLiteral("dx"));
        break;
    }
    case NodeKind::Derivative: {
        const QFontMetricsF sfm = metricsFor(level + 1);
        p->setFont(fontFor(level + 1));
        const QString head = QStringLiteral("d/dx");
        p->drawText(QPointF(x, baseline), head);
        const qreal bodyX = x + sfm.horizontalAdvance(head) + 2.0;
        const Box body = measureRow(n->arg(0), level);
        p->setFont(fontFor(level));
        p->drawText(QPointF(bodyX, baseline), QStringLiteral("("));
        const qreal inner = bodyX + fm.horizontalAdvance(QStringLiteral("("));
        drawRow(p, n->arg(0), inner, baseline, level);
        qreal cx = inner + body.width;
        p->setFont(fontFor(level));
        p->drawText(QPointF(cx, baseline), QStringLiteral(")|"));
        cx += fm.horizontalAdvance(QStringLiteral(")|"));
        drawRow(p, n->arg(1), cx, baseline + fm.descent(), level + 1);
        break;
    }
    case NodeKind::Recurring: {
        const Box inner = measureRow(n->arg(0), level);
        drawRow(p, n->arg(0), x, baseline, level);
        p->save();
        p->setPen(pen);
        p->drawLine(QPointF(x, baseline - inner.ascent - 2.0),
                    QPointF(x + inner.width, baseline - inner.ascent - 2.0));
        p->restore();
        break;
    }
    default:
        break;
    }
}

} // namespace fx

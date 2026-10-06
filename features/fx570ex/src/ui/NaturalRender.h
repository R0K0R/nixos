#pragma once
#include "core/Node.h"

#include <QFont>
#include <QPainter>
#include <QRectF>

namespace fx {

// Measured extent of a laid-out node, relative to its own baseline.
struct Box {
    qreal width = 0.0;
    qreal ascent = 0.0;
    qreal descent = 0.0;

    qreal height() const { return ascent + descent; }
};

// Recursive "natural textbook" layout: fractions stack, exponents lift and
// shrink, radicals get a drawn hook and vinculum.  Measure and draw share the
// same traversal so the cursor rectangle always matches what is painted.
class NaturalRender {
public:
    explicit NaturalRender(const QFont &baseFont, qreal basePixelSize);

    void setCursor(const Node *row, int index) { m_cursorRow = row; m_cursorIndex = index; }
    void setShowCursor(bool on) { m_showCursor = on; }

    Box measure(const Node *node, int level) const;
    Box measureRow(const Node *row, int level) const;

    void draw(QPainter *p, const Node *node, qreal x, qreal baseline, int level) const;
    void drawRow(QPainter *p, const Node *row, qreal x, qreal baseline, int level) const;

    // Valid after a draw pass; empty when the cursor was not encountered.
    QRectF cursorRect() const { return m_cursorRect; }
    void resetCursorRect() const { m_cursorRect = QRectF(); }

private:
    QFont fontFor(int level) const;
    QFontMetricsF metricsFor(int level) const;
    Box measureAtom(const QString &code, int level) const;
    void drawAtom(QPainter *p, const QString &code, qreal x, qreal baseline, int level) const;
    static qreal placeholderWidth(qreal em) { return em * 0.62; }
    void drawPlaceholder(QPainter *p, qreal x, qreal baseline, int level) const;

    QFont m_base;
    qreal m_basePixelSize;

    const Node *m_cursorRow = nullptr;
    int m_cursorIndex = 0;
    bool m_showCursor = true;
    mutable QRectF m_cursorRect;
};

} // namespace fx

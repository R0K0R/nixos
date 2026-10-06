#include "CalculatorWindow.h"
#include "DisplayWidget.h"
#include "KeyButton.h"

#include <QCheckBox>
#include <QComboBox>
#include <QDialog>
#include <QDialogButtonBox>
#include <QFormLayout>
#include <QGridLayout>
#include <QGroupBox>
#include <QKeyEvent>
#include <QLabel>
#include <QLineEdit>
#include <QMenu>
#include <QMessageBox>
#include <QSpinBox>
#include <QVBoxLayout>
#include <cmath>

namespace fx {

namespace {
// The keypad is a 30-column grid so that the six-across function rows and the
// five-across numeric rows share one layout (spans of 5 and 6 respectively).
constexpr int kGridCols = 30;
constexpr int kFnSpan = 5;
constexpr int kNumSpan = 6;
} // namespace

CalculatorWindow::CalculatorWindow(QWidget *parent)
    : QWidget(parent), m_engine(new Engine(this))
{
    setWindowTitle(QStringLiteral("CASIO fx-570EX ClassWiz"));
    setStyleSheet(QStringLiteral("QWidget { background: #3f3f43; color: #e8e8e8; }"));

    auto *outer = new QVBoxLayout(this);
    outer->setContentsMargins(16, 14, 16, 16);
    outer->setSpacing(12);

    auto *brand = new QLabel(QStringLiteral("CASIO      C L A S S W I Z      fx-570EX"), this);
    QFont bf = brand->font();
    bf.setPixelSize(11);
    bf.setBold(true);
    bf.setLetterSpacing(QFont::AbsoluteSpacing, 1.2);
    brand->setFont(bf);
    brand->setStyleSheet(QStringLiteral("color: #c9c9cf;"));
    brand->setFixedHeight(16);
    outer->addWidget(brand);

    m_display = new DisplayWidget(m_engine, this);
    outer->addWidget(m_display);

    auto *grid = new QGridLayout;
    grid->setSpacing(5);
    buildKeypad(grid);
    outer->addLayout(grid, 1); // spare height goes to the keys, not the case

    setFocusPolicy(Qt::StrongFocus);
    resize(560, 780);
}

KeyButton *CalculatorWindow::addKey(QGridLayout *grid, int row, int col, int colSpan,
                                    const QString &id, const QString &main, KeyStyle style,
                                    const QString &shift, const QString &alpha, const QString &alt)
{
    auto *b = new KeyButton(id, main, style, this);
    b->setShiftLabel(shift);
    b->setAlphaLabel(alpha);
    b->setAltLabel(alt);
    connect(b, &QAbstractButton::clicked, this, [this, id] { press(id); });
    grid->addWidget(b, row, col, 1, colSpan);
    m_keys.insert(id, b);
    return b;
}

QWidget *CalculatorWindow::buildDirectionPad()
{
    auto *pad = new QWidget(this);
    auto *g = new QGridLayout(pad);
    g->setContentsMargins(0, 0, 0, 0);
    g->setSpacing(2);

    struct Arrow { const char *id; const char *glyph; int r; int c; };
    const Arrow arrows[] = {
        { "up", "▲", 0, 1 },
        { "left", "◀", 1, 0 },
        { "right", "▶", 1, 2 },
        { "down", "▼", 2, 1 },
    };
    for (const Arrow &a : arrows) {
        auto *b = new KeyButton(QString::fromLatin1(a.id), QString::fromUtf8(a.glyph),
                                KeyStyle::Small, pad);
        b->setMinimumSize(34, 24);
        const QString id = QString::fromLatin1(a.id);
        connect(b, &QAbstractButton::clicked, this, [this, id] { press(id); });
        m_keys.insert(id, b);
        g->addWidget(b, a.r, a.c);
    }
    auto *hub = new QLabel(pad);
    hub->setFixedSize(30, 22);
    hub->setStyleSheet(QStringLiteral("background: #5a5a60; border-radius: 11px;"));
    g->addWidget(hub, 1, 1);
    return pad;
}

void CalculatorWindow::buildKeypad(QGridLayout *grid)
{
    for (int c = 0; c < kGridCols; ++c)
        grid->setColumnStretch(c, 1);

    // --- row 0/1: modifiers, cursor pad, and the two template keys ---------
    addKey(grid, 0, 0 * kFnSpan, kFnSpan, QStringLiteral("shift"), QStringLiteral("SHIFT"),
           KeyStyle::Small);
    addKey(grid, 0, 1 * kFnSpan, kFnSpan, QStringLiteral("alpha"), QStringLiteral("ALPHA"),
           KeyStyle::Small);
    grid->addWidget(buildDirectionPad(), 0, 2 * kFnSpan, 2, 2 * kFnSpan);
    addKey(grid, 0, 4 * kFnSpan, kFnSpan, QStringLiteral("menu"), QStringLiteral("MENU"),
           KeyStyle::Small, QStringLiteral("SETUP"));
    addKey(grid, 0, 5 * kFnSpan, kFnSpan, QStringLiteral("on"), QStringLiteral("ON"),
           KeyStyle::Small);

    addKey(grid, 1, 0 * kFnSpan, kFnSpan, QStringLiteral("optn"), QStringLiteral("OPTN"),
           KeyStyle::Dark);
    addKey(grid, 1, 1 * kFnSpan, kFnSpan, QStringLiteral("calc"), QStringLiteral("CALC"),
           KeyStyle::Dark, QStringLiteral("SOLVE"), QStringLiteral("="));
    addKey(grid, 1, 4 * kFnSpan, kFnSpan, QStringLiteral("integral"), QStringLiteral("∫dx"),
           KeyStyle::Dark, QStringLiteral("d/dx"));
    addKey(grid, 1, 5 * kFnSpan, kFnSpan, QStringLiteral("varx"), QStringLiteral("x"),
           KeyStyle::Dark, QStringLiteral("Σ"), QStringLiteral("Π"));

    // --- row 2 --------------------------------------------------------------
    addKey(grid, 2, 0 * kFnSpan, kFnSpan, QStringLiteral("frac"), QStringLiteral("▭/▭"),
           KeyStyle::Dark, QStringLiteral("a b/c"));
    addKey(grid, 2, 1 * kFnSpan, kFnSpan, QStringLiteral("sqrt"), QStringLiteral("√▭"),
           KeyStyle::Dark, QStringLiteral("∛▭"));
    addKey(grid, 2, 2 * kFnSpan, kFnSpan, QStringLiteral("sqr"), QStringLiteral("x²"),
           KeyStyle::Dark, QStringLiteral("x³"));
    addKey(grid, 2, 3 * kFnSpan, kFnSpan, QStringLiteral("pow"), QStringLiteral("x▪"),
           KeyStyle::Dark, QStringLiteral("▪√▭"));
    addKey(grid, 2, 4 * kFnSpan, kFnSpan, QStringLiteral("logbase"), QStringLiteral("log▭▭"),
           KeyStyle::Dark, QStringLiteral("10▪"));
    addKey(grid, 2, 5 * kFnSpan, kFnSpan, QStringLiteral("ln"), QStringLiteral("ln"),
           KeyStyle::Dark, QStringLiteral("e▪"));

    // --- row 3 --------------------------------------------------------------
    addKey(grid, 3, 0 * kFnSpan, kFnSpan, QStringLiteral("negate"), QStringLiteral("(−)"),
           KeyStyle::Dark, QStringLiteral("log"), QStringLiteral("A"));
    addKey(grid, 3, 1 * kFnSpan, kFnSpan, QStringLiteral("dms"), QStringLiteral("°′″"),
           KeyStyle::Dark, QStringLiteral("FACT"), QStringLiteral("B"));
    addKey(grid, 3, 2 * kFnSpan, kFnSpan, QStringLiteral("inv"), QStringLiteral("x⁻¹"),
           KeyStyle::Dark, QStringLiteral("x!"), QStringLiteral("C"));
    addKey(grid, 3, 3 * kFnSpan, kFnSpan, QStringLiteral("sin"), QStringLiteral("sin"),
           KeyStyle::Dark, QStringLiteral("sin⁻¹"), QStringLiteral("D"));
    addKey(grid, 3, 4 * kFnSpan, kFnSpan, QStringLiteral("cos"), QStringLiteral("cos"),
           KeyStyle::Dark, QStringLiteral("cos⁻¹"), QStringLiteral("E"));
    addKey(grid, 3, 5 * kFnSpan, kFnSpan, QStringLiteral("tan"), QStringLiteral("tan"),
           KeyStyle::Dark, QStringLiteral("tan⁻¹"), QStringLiteral("F"));

    // --- row 4 --------------------------------------------------------------
    addKey(grid, 4, 0 * kFnSpan, kFnSpan, QStringLiteral("sto"), QStringLiteral("STO"),
           KeyStyle::Dark, QStringLiteral("RECALL"));
    addKey(grid, 4, 1 * kFnSpan, kFnSpan, QStringLiteral("eng"), QStringLiteral("ENG"),
           KeyStyle::Dark, QStringLiteral("∠"), QStringLiteral("i"));
    addKey(grid, 4, 2 * kFnSpan, kFnSpan, QStringLiteral("lparen"), QStringLiteral("("),
           KeyStyle::Dark, QStringLiteral("Abs"));
    addKey(grid, 4, 3 * kFnSpan, kFnSpan, QStringLiteral("rparen"), QStringLiteral(")"),
           KeyStyle::Dark, QStringLiteral(","), QStringLiteral("x"));
    addKey(grid, 4, 4 * kFnSpan, kFnSpan, QStringLiteral("sd"), QStringLiteral("S⇔D"),
           KeyStyle::Dark, QStringLiteral("°′″⇔"), QStringLiteral("y"));
    addKey(grid, 4, 5 * kFnSpan, kFnSpan, QStringLiteral("mplus"), QStringLiteral("M+"),
           KeyStyle::Dark, QStringLiteral("M−"), QStringLiteral("M"));

    // --- numeric block (five across) ----------------------------------------
    addKey(grid, 5, 0 * kNumSpan, kNumSpan, QStringLiteral("7"), QStringLiteral("7"),
           KeyStyle::Light);
    addKey(grid, 5, 1 * kNumSpan, kNumSpan, QStringLiteral("8"), QStringLiteral("8"),
           KeyStyle::Light);
    addKey(grid, 5, 2 * kNumSpan, kNumSpan, QStringLiteral("9"), QStringLiteral("9"),
           KeyStyle::Light);
    addKey(grid, 5, 3 * kNumSpan, kNumSpan, QStringLiteral("del"), QStringLiteral("DEL"),
           KeyStyle::Accent, QStringLiteral("INS"));
    addKey(grid, 5, 4 * kNumSpan, kNumSpan, QStringLiteral("ac"), QStringLiteral("AC"),
           KeyStyle::Accent, QStringLiteral("OFF"));

    addKey(grid, 6, 0 * kNumSpan, kNumSpan, QStringLiteral("4"), QStringLiteral("4"),
           KeyStyle::Light);
    addKey(grid, 6, 1 * kNumSpan, kNumSpan, QStringLiteral("5"), QStringLiteral("5"),
           KeyStyle::Light);
    addKey(grid, 6, 2 * kNumSpan, kNumSpan, QStringLiteral("6"), QStringLiteral("6"),
           KeyStyle::Light);
    addKey(grid, 6, 3 * kNumSpan, kNumSpan, QStringLiteral("mul"), QStringLiteral("×"),
           KeyStyle::Dark, QStringLiteral("nPr"));
    addKey(grid, 6, 4 * kNumSpan, kNumSpan, QStringLiteral("div"), QStringLiteral("÷"),
           KeyStyle::Dark, QStringLiteral("nCr"));

    addKey(grid, 7, 0 * kNumSpan, kNumSpan, QStringLiteral("1"), QStringLiteral("1"),
           KeyStyle::Light);
    addKey(grid, 7, 1 * kNumSpan, kNumSpan, QStringLiteral("2"), QStringLiteral("2"),
           KeyStyle::Light);
    addKey(grid, 7, 2 * kNumSpan, kNumSpan, QStringLiteral("3"), QStringLiteral("3"),
           KeyStyle::Light);
    addKey(grid, 7, 3 * kNumSpan, kNumSpan, QStringLiteral("add"), QStringLiteral("+"),
           KeyStyle::Dark, QStringLiteral("Pol"));
    addKey(grid, 7, 4 * kNumSpan, kNumSpan, QStringLiteral("sub"), QStringLiteral("−"),
           KeyStyle::Dark, QStringLiteral("Rec"));

    addKey(grid, 8, 0 * kNumSpan, kNumSpan, QStringLiteral("0"), QStringLiteral("0"),
           KeyStyle::Light, QStringLiteral("Rnd"));
    addKey(grid, 8, 1 * kNumSpan, kNumSpan, QStringLiteral("dot"), QStringLiteral("."),
           KeyStyle::Light, QStringLiteral("Ran#"), QStringLiteral("RanInt"));
    addKey(grid, 8, 2 * kNumSpan, kNumSpan, QStringLiteral("exp"), QStringLiteral("×10ˣ"),
           KeyStyle::Light, QStringLiteral("π"));
    addKey(grid, 8, 3 * kNumSpan, kNumSpan, QStringLiteral("ans"), QStringLiteral("Ans"),
           KeyStyle::Light, QStringLiteral("e"));
    addKey(grid, 8, 4 * kNumSpan, kNumSpan, QStringLiteral("equals"), QStringLiteral("="),
           KeyStyle::Light, QStringLiteral("%"));
}

// ---------------------------------------------------------------------------

void CalculatorWindow::setShift(bool on)
{
    m_shift = on;
    if (on)
        m_alpha = false;
    m_display->setShiftActive(m_shift);
    m_display->setAlphaActive(m_alpha);
    if (auto *b = m_keys.value(QStringLiteral("shift")))
        b->setHighlighted(m_shift);
    if (auto *b = m_keys.value(QStringLiteral("alpha")))
        b->setHighlighted(m_alpha);
}

void CalculatorWindow::setAlpha(bool on)
{
    m_alpha = on;
    if (on)
        m_shift = false;
    m_display->setShiftActive(m_shift);
    m_display->setAlphaActive(m_alpha);
    if (auto *b = m_keys.value(QStringLiteral("shift")))
        b->setHighlighted(m_shift);
    if (auto *b = m_keys.value(QStringLiteral("alpha")))
        b->setHighlighted(m_alpha);
}

void CalculatorWindow::clearModifiers()
{
    setShift(false);
    setAlpha(false);
}

void CalculatorWindow::press(const QString &id)
{
    if (id == QStringLiteral("shift")) {
        setShift(!m_shift);
        return;
    }
    if (id == QStringLiteral("alpha")) {
        setAlpha(!m_alpha);
        return;
    }

    // STO / RECALL swallow the next variable key.
    if (m_storePending || m_recallPending) {
        static const QHash<QString, QString> varForKey = {
            { QStringLiteral("negate"), QStringLiteral("A") },
            { QStringLiteral("dms"), QStringLiteral("B") },
            { QStringLiteral("inv"), QStringLiteral("C") },
            { QStringLiteral("sin"), QStringLiteral("D") },
            { QStringLiteral("cos"), QStringLiteral("E") },
            { QStringLiteral("tan"), QStringLiteral("F") },
            { QStringLiteral("rparen"), QStringLiteral("x") },
            { QStringLiteral("sd"), QStringLiteral("y") },
            { QStringLiteral("mplus"), QStringLiteral("M") },
        };
        const QString var = varForKey.value(id);
        if (!var.isEmpty()) {
            if (m_storePending)
                m_engine->setVariable(var, m_engine->lastResult());
            else
                m_engine->insertAtom(var);
        }
        m_storePending = false;
        m_recallPending = false;
        clearModifiers();
        return;
    }

    const bool wasShift = m_shift;
    const bool wasAlpha = m_alpha;
    clearModifiers();

    if (wasShift)
        handleShifted(id);
    else if (wasAlpha)
        handleAlpha(id);
    else
        handlePlain(id);
}

void CalculatorWindow::handlePlain(const QString &id)
{
    Engine *e = m_engine;

    if (id.size() == 1 && id.at(0).isDigit()) {
        e->insertAtom(id);
        return;
    }

    static const QHash<QString, QString> atoms = {
        { QStringLiteral("dot"), QStringLiteral(".") },
        { QStringLiteral("exp"), QStringLiteral("E") },
        { QStringLiteral("ans"), QStringLiteral("Ans") },
        { QStringLiteral("add"), QStringLiteral("+") },
        { QStringLiteral("sub"), QStringLiteral("-") },
        { QStringLiteral("mul"), QStringLiteral("*") },
        { QStringLiteral("div"), QStringLiteral("/") },
        { QStringLiteral("lparen"), QStringLiteral("(") },
        { QStringLiteral("rparen"), QStringLiteral(")") },
        { QStringLiteral("negate"), QStringLiteral("neg") },
        { QStringLiteral("inv"), QStringLiteral("inv") },
        { QStringLiteral("sqr"), QStringLiteral("sqr") },
        { QStringLiteral("dms"), QStringLiteral("deg") },
        { QStringLiteral("varx"), QStringLiteral("x") },
        { QStringLiteral("sin"), QStringLiteral("sin(") },
        { QStringLiteral("cos"), QStringLiteral("cos(") },
        { QStringLiteral("tan"), QStringLiteral("tan(") },
        { QStringLiteral("ln"), QStringLiteral("ln(") },
    };
    auto it = atoms.constFind(id);
    if (it != atoms.constEnd()) {
        e->insertAtom(it.value());
        return;
    }

    if (id == QStringLiteral("frac"))      { e->insertStructure(NodeKind::Frac); return; }
    if (id == QStringLiteral("sqrt"))      { e->insertStructure(NodeKind::Sqrt); return; }
    if (id == QStringLiteral("pow"))       { e->insertStructure(NodeKind::Power); return; }
    if (id == QStringLiteral("logbase"))   { e->insertStructure(NodeKind::LogBase); return; }
    if (id == QStringLiteral("integral"))  { e->insertStructure(NodeKind::Integral); return; }

    if (id == QStringLiteral("equals"))    { e->execute(); return; }
    if (id == QStringLiteral("del"))       { e->backspace(); return; }
    if (id == QStringLiteral("ac"))        { e->clearAll(); return; }
    if (id == QStringLiteral("on"))        { e->clearAll(); e->clearVariables(); return; }
    if (id == QStringLiteral("sd"))        { e->toggleStandardDecimal(); return; }

    if (id == QStringLiteral("left"))  { e->moveLeft(); return; }
    if (id == QStringLiteral("right")) { e->moveRight(); return; }
    if (id == QStringLiteral("up"))    { e->moveUp(); return; }
    if (id == QStringLiteral("down"))  { e->moveDown(); return; }

    if (id == QStringLiteral("mplus")) {
        if (m_engine->hasResult())
            e->memoryAdd(m_engine->lastResult().real().d);
        return;
    }
    if (id == QStringLiteral("sto"))   { m_storePending = true; return; }
    if (id == QStringLiteral("menu"))  { showSettings(); return; }
    if (id == QStringLiteral("optn"))  { showFunctionMenu(); return; }
    if (id == QStringLiteral("calc"))  { showVariables(); return; }
    if (id == QStringLiteral("eng"))   {
        FormatOptions f = e->formatOptions();
        f.format = (f.format == DisplayFormat::Eng) ? DisplayFormat::Norm1 : DisplayFormat::Eng;
        e->setFormatOptions(f);
        return;
    }
}

void CalculatorWindow::handleShifted(const QString &id)
{
    Engine *e = m_engine;

    static const QHash<QString, QString> atoms = {
        { QStringLiteral("negate"), QStringLiteral("log(") },
        { QStringLiteral("inv"), QStringLiteral("!") },
        { QStringLiteral("sqr"), QStringLiteral("cube") },
        { QStringLiteral("sin"), QStringLiteral("asin(") },
        { QStringLiteral("cos"), QStringLiteral("acos(") },
        { QStringLiteral("tan"), QStringLiteral("atan(") },
        { QStringLiteral("ln"), QStringLiteral("e^(") },
        { QStringLiteral("logbase"), QStringLiteral("10^(") },
        { QStringLiteral("rparen"), QStringLiteral(",") },
        { QStringLiteral("eng"), QStringLiteral("angle") },
        { QStringLiteral("mul"), QStringLiteral("nPr") },
        { QStringLiteral("div"), QStringLiteral("nCr") },
        { QStringLiteral("add"), QStringLiteral("Pol(") },
        { QStringLiteral("sub"), QStringLiteral("Rec(") },
        { QStringLiteral("exp"), QStringLiteral("pi") },
        { QStringLiteral("ans"), QStringLiteral("e") },
        { QStringLiteral("equals"), QStringLiteral("pct") },
        { QStringLiteral("dot"), QStringLiteral("Ran#") },
        { QStringLiteral("0"), QStringLiteral("Rnd(") },
    };
    auto it = atoms.constFind(id);
    if (it != atoms.constEnd()) {
        e->insertAtom(it.value());
        return;
    }

    if (id == QStringLiteral("frac"))     { e->insertStructure(NodeKind::MixedFrac); return; }
    if (id == QStringLiteral("pow"))      { e->insertStructure(NodeKind::Root); return; }
    if (id == QStringLiteral("lparen"))   { e->insertStructure(NodeKind::Abs); return; }
    if (id == QStringLiteral("integral")) { e->insertStructure(NodeKind::Derivative); return; }
    if (id == QStringLiteral("varx"))     { e->insertStructure(NodeKind::Sum); return; }
    if (id == QStringLiteral("sqrt")) {
        // SHIFT+root is the cube root: an x-root template with the index filled in.
        e->insertStructure(NodeKind::Root);
        e->insertAtom(QStringLiteral("3"));
        e->moveRight();
        return;
    }

    if (id == QStringLiteral("sto"))   { m_recallPending = true; return; }
    if (id == QStringLiteral("calc"))  { runSolve(); return; }
    if (id == QStringLiteral("menu"))  { showSettings(); return; }
    if (id == QStringLiteral("dms"))   { primeFactorise(); return; }
    if (id == QStringLiteral("mplus")) {
        if (m_engine->hasResult())
            e->memoryAdd(-m_engine->lastResult().real().d);
        return;
    }
    if (id == QStringLiteral("del")) {
        m_insert = !m_insert;
        m_display->setInsertMode(m_insert);
        return;
    }
    if (id == QStringLiteral("ac"))    { e->clearAll(); return; }
    if (id == QStringLiteral("left"))  { e->moveHome(); return; }
    if (id == QStringLiteral("right")) { e->moveEnd(); return; }
    if (id == QStringLiteral("eng")) {
        FormatOptions f = e->formatOptions();
        f.format = DisplayFormat::Norm1;
        e->setFormatOptions(f);
        return;
    }
}

void CalculatorWindow::handleAlpha(const QString &id)
{
    static const QHash<QString, QString> vars = {
        { QStringLiteral("negate"), QStringLiteral("A") },
        { QStringLiteral("dms"), QStringLiteral("B") },
        { QStringLiteral("inv"), QStringLiteral("C") },
        { QStringLiteral("sin"), QStringLiteral("D") },
        { QStringLiteral("cos"), QStringLiteral("E") },
        { QStringLiteral("tan"), QStringLiteral("F") },
        { QStringLiteral("rparen"), QStringLiteral("x") },
        { QStringLiteral("sd"), QStringLiteral("y") },
        { QStringLiteral("mplus"), QStringLiteral("M") },
        { QStringLiteral("eng"), QStringLiteral("i") },
    };
    auto it = vars.constFind(id);
    if (it != vars.constEnd()) {
        m_engine->insertAtom(it.value());
        return;
    }
    if (id == QStringLiteral("dot"))  { m_engine->insertAtom(QStringLiteral("RanInt(")); return; }
    if (id == QStringLiteral("varx")) { m_engine->insertStructure(NodeKind::Product); return; }
    // The "=" printed above CALC is the equation sign, not the execute key --
    // it is what lets you enter "A=B" for SOLVE to work on.
    if (id == QStringLiteral("calc")) { m_engine->insertAtom(QStringLiteral("=")); return; }
}

// ---------------------------------------------------------------------------

void CalculatorWindow::showSettings()
{
    QDialog dlg(this);
    dlg.setWindowTitle(QStringLiteral("SETUP"));
    auto *form = new QFormLayout(&dlg);

    auto *angle = new QComboBox(&dlg);
    angle->addItems({ QStringLiteral("Degree"), QStringLiteral("Radian"), QStringLiteral("Gradian") });
    angle->setCurrentIndex(static_cast<int>(m_engine->angleUnit()));
    form->addRow(QStringLiteral("Angle unit"), angle);

    const FormatOptions cur = m_engine->formatOptions();
    auto *fmt = new QComboBox(&dlg);
    fmt->addItems({ QStringLiteral("Norm 1"), QStringLiteral("Norm 2"), QStringLiteral("Fix"),
                    QStringLiteral("Sci"), QStringLiteral("Eng") });
    fmt->setCurrentIndex(static_cast<int>(cur.format));
    form->addRow(QStringLiteral("Number format"), fmt);

    auto *digits = new QSpinBox(&dlg);
    digits->setRange(0, 9);
    digits->setValue(cur.digits);
    form->addRow(QStringLiteral("Fix / Sci digits"), digits);

    auto *sep = new QCheckBox(QStringLiteral("Show thousands separator"), &dlg);
    sep->setChecked(cur.thousandsSeparator);
    form->addRow(sep);

    auto *cplx = new QCheckBox(QStringLiteral("Complex results (a+bi)"), &dlg);
    cplx->setChecked(m_engine->complexMode());
    form->addRow(cplx);

    auto *buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel, &dlg);
    connect(buttons, &QDialogButtonBox::accepted, &dlg, &QDialog::accept);
    connect(buttons, &QDialogButtonBox::rejected, &dlg, &QDialog::reject);
    form->addRow(buttons);

    if (dlg.exec() != QDialog::Accepted)
        return;

    m_engine->setAngleUnit(static_cast<AngleUnit>(angle->currentIndex()));
    FormatOptions f = cur;
    f.format = static_cast<DisplayFormat>(fmt->currentIndex());
    f.digits = digits->value();
    f.thousandsSeparator = sep->isChecked();
    m_engine->setFormatOptions(f);
    m_engine->setComplexMode(cplx->isChecked());
}

void CalculatorWindow::showVariables()
{
    QDialog dlg(this);
    dlg.setWindowTitle(QStringLiteral("Variables"));
    auto *form = new QFormLayout(&dlg);

    const QStringList names = { QStringLiteral("A"), QStringLiteral("B"), QStringLiteral("C"),
                                QStringLiteral("D"), QStringLiteral("E"), QStringLiteral("F"),
                                QStringLiteral("x"), QStringLiteral("y"), QStringLiteral("M"),
                                QStringLiteral("Ans") };
    QHash<QString, QLineEdit *> edits;
    const FormatOptions fmt = m_engine->formatOptions();
    for (const QString &n : names) {
        auto *edit = new QLineEdit(formatValue(m_engine->variable(n), fmt), &dlg);
        if (n == QStringLiteral("Ans"))
            edit->setReadOnly(true);
        edits.insert(n, edit);
        form->addRow(n, edit);
    }

    auto *buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel, &dlg);
    connect(buttons, &QDialogButtonBox::accepted, &dlg, &QDialog::accept);
    connect(buttons, &QDialogButtonBox::rejected, &dlg, &QDialog::reject);
    form->addRow(buttons);

    if (dlg.exec() != QDialog::Accepted)
        return;
    for (auto it = edits.constBegin(); it != edits.constEnd(); ++it) {
        if (it.key() == QStringLiteral("Ans"))
            continue;
        bool ok = false;
        const double v = it.value()->text().toDouble(&ok);
        if (ok)
            m_engine->setVariable(it.key(), Value(Real(v, Exact::fromDouble(v))));
    }
}

void CalculatorWindow::showFunctionMenu()
{
    QMenu menu(this);
    struct Item { const char *label; const char *atom; NodeKind structure; bool isStructure; };
    const QVector<QPair<QString, QString>> functions = {
        { QStringLiteral("Abs("), QStringLiteral("Abs(") },
        { QStringLiteral("GCD("), QStringLiteral("GCD(") },
        { QStringLiteral("LCM("), QStringLiteral("LCM(") },
        { QStringLiteral("Int("), QStringLiteral("Int(") },
        { QStringLiteral("Intg("), QStringLiteral("Intg(") },
        { QStringLiteral("Pol("), QStringLiteral("Pol(") },
        { QStringLiteral("Rec("), QStringLiteral("Rec(") },
        { QStringLiteral("RanInt("), QStringLiteral("RanInt(") },
        { QStringLiteral("sinh("), QStringLiteral("sinh(") },
        { QStringLiteral("cosh("), QStringLiteral("cosh(") },
        { QStringLiteral("tanh("), QStringLiteral("tanh(") },
        { QStringLiteral("Arg("), QStringLiteral("Arg(") },
        { QStringLiteral("Conjg("), QStringLiteral("Conjg(") },
        { QStringLiteral("∛ (cube root)"), QStringLiteral("cbrt(") },
    };
    for (const auto &f : functions) {
        const QString atom = f.second;
        menu.addAction(f.first, this, [this, atom] { m_engine->insertAtom(atom); });
    }
    menu.exec(QCursor::pos());
}

/*
  SHIFT+CALC. The real unit shows a screen with the equation, the variable it
  solved for, the value, and "L-R" -- how far apart the two sides ended up,
  which is the only honest way to tell a converged root from a near miss.
*/
void CalculatorWindow::runSolve()
{
    if (m_engine->isEmpty()) {
        QMessageBox::information(this, QStringLiteral("SOLVE"),
                                 QStringLiteral("Enter an equation first, for example  A=B  "
                                                "(the = sign is ALPHA then CALC)."));
        return;
    }

    const QStringList vars = m_engine->entryVariables();
    if (vars.isEmpty()) {
        QMessageBox::information(this, QStringLiteral("SOLVE"),
                                 QStringLiteral("There is no variable to solve for."));
        return;
    }

    // One unknown needs no question; several get the same choice the unit
    // offers, defaulting to the first in A-F, x, y, z, M order.
    QString chosen = vars.first();
    if (vars.size() > 1) {
        QDialog pick(this);
        pick.setWindowTitle(QStringLiteral("SOLVE"));
        auto *form = new QFormLayout(&pick);
        auto *box = new QComboBox(&pick);
        box->addItems(vars);
        form->addRow(QStringLiteral("Solve for"), box);
        auto *buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel, &pick);
        connect(buttons, &QDialogButtonBox::accepted, &pick, &QDialog::accept);
        connect(buttons, &QDialogButtonBox::rejected, &pick, &QDialog::reject);
        form->addRow(buttons);
        if (pick.exec() != QDialog::Accepted)
            return;
        chosen = box->currentText();
    }

    const Engine::SolveResult r = m_engine->solveForVariable(chosen);
    if (!r.ok) {
        QMessageBox::warning(this, QStringLiteral("SOLVE"),
                             r.error.isEmpty() ? QStringLiteral("Can't Solve") : r.error);
        return;
    }

    const FormatOptions fmt = m_engine->formatOptions();
    QMessageBox::information(
            this, QStringLiteral("SOLVE"),
            QStringLiteral("%1 = %2\n\nL−R = %3")
                    .arg(r.variable, formatNumber(r.value, fmt), formatNumber(r.residual, fmt)));
}

void CalculatorWindow::primeFactorise()
{
    if (!m_engine->hasResult() || !m_engine->lastResult().isReal()) {
        QMessageBox::information(this, QStringLiteral("FACT"),
                                 QStringLiteral("Calculate a positive integer first."));
        return;
    }
    double d = m_engine->lastResult().real().d;
    if (d != std::floor(d) || d < 2 || d > 1e10) {
        QMessageBox::information(this, QStringLiteral("FACT"),
                                 QStringLiteral("FACT needs an integer from 2 to 10^10."));
        return;
    }
    long long n = static_cast<long long>(d);
    QStringList parts;
    for (long long p = 2; p * p <= n; ++p) {
        int count = 0;
        while (n % p == 0) {
            n /= p;
            ++count;
        }
        if (count == 1)
            parts << QString::number(p);
        else if (count > 1)
            parts << QStringLiteral("%1^%2").arg(p).arg(count);
    }
    if (n > 1)
        parts << QString::number(n);
    QMessageBox::information(this, QStringLiteral("FACT"),
                             QStringLiteral("%1 = %2")
                                     .arg(static_cast<long long>(d))
                                     .arg(parts.join(QStringLiteral(" × "))));
}

// ---------------------------------------------------------------------------

void CalculatorWindow::keyPressEvent(QKeyEvent *event)
{
    const QString t = event->text();
    const int k = event->key();

    switch (k) {
    case Qt::Key_Left:      press(QStringLiteral("left"));   return;
    case Qt::Key_Right:     press(QStringLiteral("right"));  return;
    case Qt::Key_Up:        press(QStringLiteral("up"));     return;
    case Qt::Key_Down:      press(QStringLiteral("down"));   return;
    case Qt::Key_Backspace: press(QStringLiteral("del"));    return;
    case Qt::Key_Delete:    press(QStringLiteral("ac"));     return;
    case Qt::Key_Escape:    press(QStringLiteral("ac"));     return;
    case Qt::Key_Return:
    case Qt::Key_Enter:
        // Ctrl+Enter is SOLVE, the keyboard route to SHIFT+CALC.
        if (event->modifiers().testFlag(Qt::ControlModifier))
            runSolve();
        else
            press(QStringLiteral("equals"));
        return;
    default:
        break;
    }

    if (t.size() == 1) {
        const QChar ch = t.at(0);
        if (ch.isDigit()) {
            press(QString(ch));
            return;
        }
        switch (ch.unicode()) {
        case '+': press(QStringLiteral("add")); return;
        case '-': press(QStringLiteral("sub")); return;
        case '*': press(QStringLiteral("mul")); return;
        case '/': press(QStringLiteral("div")); return;
        case '.': press(QStringLiteral("dot")); return;
        case '(': press(QStringLiteral("lparen")); return;
        case ')': press(QStringLiteral("rparen")); return;
        case '^': press(QStringLiteral("pow")); return;
        /*
          The equation sign, not EXE. On the calculator itself `=` IS the
          execute key, but a PC keyboard already has Enter for that, and
          without this there is no way to type the `=` in "A=B" that SOLVE
          needs -- on the hardware it is the ALPHA legend above CALC.
        */
        case '=': m_engine->insertAtom(QStringLiteral("=")); return;
        case '!': m_engine->insertAtom(QStringLiteral("!")); return;
        case ',': m_engine->insertAtom(QStringLiteral(",")); return;
        case 's': press(QStringLiteral("sin")); return;
        case 'c': press(QStringLiteral("cos")); return;
        case 't': press(QStringLiteral("tan")); return;
        case 'l': press(QStringLiteral("ln")); return;
        case 'r': press(QStringLiteral("sqrt")); return;
        case 'f': press(QStringLiteral("frac")); return;
        case 'p': m_engine->insertAtom(QStringLiteral("pi")); return;
        case 'x': m_engine->insertAtom(QStringLiteral("x")); return;
        default:
            break;
        }
    }
    QWidget::keyPressEvent(event);
}

} // namespace fx

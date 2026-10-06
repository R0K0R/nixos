#include "Engine.h"
#include "Parser.h"

#include <QSet>
#include <QStringList>
#include <cmath>

namespace fx {

namespace {

// Variable names SOLVE is allowed to treat as the unknown, in the order the
// real unit offers them.
const QStringList &solvableNames()
{
    static const QStringList names = {
        QStringLiteral("x"), QStringLiteral("y"), QStringLiteral("z"),
        QStringLiteral("A"), QStringLiteral("B"), QStringLiteral("C"),
        QStringLiteral("D"), QStringLiteral("E"), QStringLiteral("F"),
        QStringLiteral("M")
    };
    return names;
}

void collectVariables(const AstP &node, QSet<QString> &out)
{
    if (!node)
        return;
    if (node->op == AstOp::Variable || node->op == AstOp::Store)
        out.insert(node->name);
    for (const AstP &child : node->args)
        collectVariables(child, out);
}

} // namespace

namespace {

int structureArgCount(NodeKind kind)
{
    switch (kind) {
    case NodeKind::Frac:       return 2;
    case NodeKind::MixedFrac:  return 3;
    case NodeKind::Power:      return 1;
    case NodeKind::Sqrt:       return 1;
    case NodeKind::Root:       return 2;
    case NodeKind::LogBase:    return 2;
    case NodeKind::Abs:        return 1;
    case NodeKind::Sum:        return 3;
    case NodeKind::Product:    return 3;
    case NodeKind::Integral:   return 3;
    case NodeKind::Derivative: return 2;
    case NodeKind::Recurring:  return 1;
    default:                   return 0;
    }
}

// Which argument the cursor lands in when the template is inserted, and how
// Up/Down walk between the arguments.
int entryArg(NodeKind kind)
{
    switch (kind) {
    case NodeKind::Root:     return 0; // index first, like the real x-root key
    case NodeKind::Integral: return 1; // lower limit first
    default:                 return 0;
    }
}

} // namespace

Engine::Engine(QObject *parent)
    : QObject(parent), m_root(Node::makeRow())
{
    m_cursor = Cursor{ m_root.get(), 0 };
    m_ctx.vars[QStringLiteral("Ans")] = Value(Real(0.0, Exact::rational(0)));
    m_ctx.vars[QStringLiteral("M")] = Value(Real(0.0, Exact::rational(0)));
}

void Engine::placeCursor(Node *row, int index)
{
    m_cursor.row = row;
    m_cursor.index = qBound(0, index, row->childCount());
    emit stateChanged();
}

void Engine::insertAtom(const QString &code)
{
    m_cursor.row->insertChild(m_cursor.index, Node::makeAtom(code));
    ++m_cursor.index;
    m_historyPos = -1;
    emit stateChanged();
}

void Engine::insertText(const QString &literal)
{
    for (const QChar &ch : literal)
        insertAtom(QString(ch));
}

void Engine::insertStructure(NodeKind kind)
{
    const int args = structureArgCount(kind);
    if (args == 0)
        return;
    NodeP node = Node::makeStructure(kind, args);
    Node *raw = node.get();
    m_cursor.row->insertChild(m_cursor.index, std::move(node));
    ++m_cursor.index;
    m_historyPos = -1;
    placeCursor(raw->arg(entryArg(kind)), 0);
}

bool Engine::backspace()
{
    if (m_cursor.index > 0) {
        m_cursor.row->takeChild(m_cursor.index - 1);
        --m_cursor.index;
        m_historyPos = -1;
        emit stateChanged();
        return true;
    }
    // At the start of a structure argument: step out and delete the structure
    // if every argument is empty, otherwise just move out of it.
    Node *row = m_cursor.row;
    Node *structure = row->parent();
    if (!structure || !structure->isStructure())
        return false;
    Node *outer = structure->parent();
    if (!outer || !outer->isRow())
        return false;
    const int idx = structure->indexInParent();

    bool allEmpty = true;
    for (int i = 0; i < structure->argCount(); ++i)
        if (structure->arg(i)->childCount() > 0)
            allEmpty = false;

    if (allEmpty) {
        outer->takeChild(idx);
        placeCursor(outer, idx);
    } else {
        placeCursor(outer, idx);
    }
    m_historyPos = -1;
    return true;
}

void Engine::clearEntry()
{
    m_root = Node::makeRow();
    m_cursor = Cursor{ m_root.get(), 0 };
    m_historyPos = -1;
    emit stateChanged();
}

void Engine::clearAll()
{
    clearEntry();
    m_hasResult = false;
    m_resultText.clear();
    m_altText.clear();
    m_errorText.clear();
    emit stateChanged();
}

bool Engine::stepOutRight()
{
    Node *row = m_cursor.row;
    Node *structure = row->parent();
    if (!structure || !structure->isStructure())
        return false;
    const int argIdx = row->indexInParent();
    if (argIdx + 1 < structure->argCount()) {
        placeCursor(structure->arg(argIdx + 1), 0);
        return true;
    }
    Node *outer = structure->parent();
    if (!outer || !outer->isRow())
        return false;
    placeCursor(outer, structure->indexInParent() + 1);
    return true;
}

bool Engine::stepOutLeft()
{
    Node *row = m_cursor.row;
    Node *structure = row->parent();
    if (!structure || !structure->isStructure())
        return false;
    const int argIdx = row->indexInParent();
    if (argIdx > 0) {
        Node *prev = structure->arg(argIdx - 1);
        placeCursor(prev, prev->childCount());
        return true;
    }
    Node *outer = structure->parent();
    if (!outer || !outer->isRow())
        return false;
    placeCursor(outer, structure->indexInParent());
    return true;
}

bool Engine::moveRight()
{
    Node *row = m_cursor.row;
    if (m_cursor.index < row->childCount()) {
        Node *next = row->childAt(m_cursor.index);
        if (next->isStructure()) {
            placeCursor(next->arg(0), 0);
            return true;
        }
        placeCursor(row, m_cursor.index + 1);
        return true;
    }
    return stepOutRight();
}

bool Engine::moveLeft()
{
    Node *row = m_cursor.row;
    if (m_cursor.index > 0) {
        Node *prev = row->childAt(m_cursor.index - 1);
        if (prev->isStructure()) {
            Node *last = prev->arg(prev->argCount() - 1);
            placeCursor(last, last->childCount());
            return true;
        }
        placeCursor(row, m_cursor.index - 1);
        return true;
    }
    return stepOutLeft();
}

bool Engine::moveUp()
{
    Node *structure = m_cursor.row->parent();
    if (!structure || !structure->isStructure())
        return historyPrev();
    const int argIdx = m_cursor.row->indexInParent();
    if (argIdx > 0) {
        placeCursor(structure->arg(argIdx - 1), structure->arg(argIdx - 1)->childCount());
        return true;
    }
    return false;
}

bool Engine::moveDown()
{
    Node *structure = m_cursor.row->parent();
    if (!structure || !structure->isStructure())
        return historyNext();
    const int argIdx = m_cursor.row->indexInParent();
    if (argIdx + 1 < structure->argCount()) {
        placeCursor(structure->arg(argIdx + 1), 0);
        return true;
    }
    return false;
}

void Engine::moveHome()
{
    placeCursor(m_root.get(), 0);
}

void Engine::moveEnd()
{
    placeCursor(m_root.get(), m_root->childCount());
}

// ---------------------------------------------------------------------------

void Engine::rebuildResultStrings(const Value &v)
{
    m_altText.clear();
    m_showingAlternate = false;

    if (v.isReal()) {
        const Real &r = v.real();
        const QString decimal = formatNumber(r.d, m_fmt);
        QString exact;
        if (r.hasExact() && !r.e.isInteger()) {
            exact = r.e.toDisplay();
            // Only offer the exact form when it is genuinely more informative.
            if (exact == decimal)
                exact.clear();
        }
        if (!exact.isEmpty()) {
            m_resultText = exact;   // a ClassWiz shows the standard form first
            m_altText = decimal;
        } else {
            m_resultText = decimal;
        }
        return;
    }
    m_resultText = formatValue(v, m_fmt);
}

bool Engine::execute()
{
    m_errorText.clear();
    try {
        AstP ast = Parser::parseRow(m_root.get());
        Evaluator ev(m_ctx);
        Value result = ev.eval(ast);

        m_ctx.vars[QStringLiteral("PreAns")] = m_ctx.vars.value(QStringLiteral("Ans"));
        m_ctx.vars[QStringLiteral("Ans")] = result;
        m_lastResult = result;
        m_hasResult = true;
        rebuildResultStrings(result);

        HistoryEntry entry;
        entry.expression = std::shared_ptr<Node>(m_root->clone().release());
        entry.resultText = m_resultText;
        entry.altText = m_altText;
        entry.result = result;
        m_history.append(entry);
        if (m_history.size() > 200)
            m_history.remove(0);
        m_historyPos = -1;

        emit stateChanged();
        return true;
    } catch (const CalcError &e) {
        m_hasResult = false;
        m_errorText = e.title();
        emit stateChanged();
        return false;
    }
}

void Engine::toggleStandardDecimal()
{
    if (m_altText.isEmpty())
        return;
    std::swap(m_resultText, m_altText);
    m_showingAlternate = !m_showingAlternate;
    emit stateChanged();
}

// ---------------------------------------------------------------------------

QStringList Engine::entryVariables() const
{
    QSet<QString> found;
    try {
        AstP ast = Parser::parseRow(m_root.get());
        collectVariables(ast, found);
    } catch (const CalcError &) {
        return {};
    }
    QStringList ordered;
    for (const QString &n : solvableNames())
        if (found.contains(n))
            ordered << n;
    return ordered;
}

Engine::SolveResult Engine::solveForVariable(const QString &preferred)
{
    SolveResult result;

    AstP ast;
    try {
        ast = Parser::parseRow(m_root.get());
    } catch (const CalcError &e) {
        result.error = e.title();
        return result;
    }

    // `left = right` solves left - right; a bare expression solves expr = 0.
    AstP target = ast;
    if (ast->op == AstOp::Equality)
        target = Ast::binary(AstOp::Sub, ast->args[0], ast->args[1]);

    QStringList candidates = entryVariables();
    if (!preferred.isEmpty())
        result.variable = preferred;
    else if (!candidates.isEmpty())
        result.variable = candidates.first();
    else {
        result.error = QStringLiteral("Variable ERROR");
        return result;
    }

    const Value saved = m_ctx.vars.value(result.variable);

    /*
      f is deliberately partial: a trial point can divide by zero or take the
      log of a negative, and that is a property of the point, not of the
      equation. Those are skipped rather than aborting the solve.
    */
    auto f = [&](double v, bool *ok) -> double {
        m_ctx.vars[result.variable] = Value(Real(v));
        try {
            Evaluator ev(m_ctx);
            const double y = ev.eval(target).d();
            *ok = std::isfinite(y);
            return y;
        } catch (const CalcError &) {
            *ok = false;
            return 0.0;
        }
    };

    auto finish = [&](bool converged, double root) {
        if (!converged) {
            m_ctx.vars[result.variable] = saved;
            if (result.error.isEmpty())
                result.error = QStringLiteral("Can't Solve");
            return;
        }
        bool ok = false;
        const double residual = f(root, &ok);
        result.ok = true;
        result.value = root;
        result.residual = ok ? residual : 0.0;
        m_ctx.vars[result.variable] = Value(Real(root, Exact::fromDouble(root)));

        m_lastResult = Value(Real(root, Exact::fromDouble(root)));
        m_hasResult = true;
        m_errorText.clear();
        rebuildResultStrings(m_lastResult);
        emit stateChanged();
    };

    // Newton-Raphson from the variable's current value, which is how the real
    // unit seeds it -- a good guess left in X makes it find the nearby root.
    double x = saved.isReal() ? saved.real().d : 0.0;
    if (!std::isfinite(x))
        x = 0.0;

    for (int iter = 0; iter < 100; ++iter) {
        bool ok = false;
        const double fx = f(x, &ok);
        if (!ok)
            break;
        if (std::fabs(fx) < 1e-12 * std::max(1.0, std::fabs(x))) {
            finish(true, x);
            return result;
        }
        const double h = std::max(1e-7, std::fabs(x) * 1e-7);
        bool okA = false, okB = false;
        const double fa = f(x + h, &okA);
        const double fb = f(x - h, &okB);
        if (!okA || !okB)
            break;
        const double slope = (fa - fb) / (2.0 * h);
        if (std::fabs(slope) < 1e-14)
            break;
        const double next = x - fx / slope;
        if (!std::isfinite(next))
            break;
        if (std::fabs(next - x) < 1e-13 * std::max(1.0, std::fabs(x))) {
            finish(true, next);
            return result;
        }
        x = next;
    }

    /*
      Newton gave up -- a flat derivative, a step off a cliff, or a bad seed.
      Sweep for a sign change and bisect, which cannot diverge and finds the
      root nearest the origin rather than the one nearest the seed.
    */
    constexpr int kSamples = 4001;
    constexpr double kSpan = 1000.0;
    double prevX = 0.0, prevY = 0.0;
    bool havePrev = false;
    for (int i = 0; i < kSamples; ++i) {
        const double sx = -kSpan + (2.0 * kSpan * i) / (kSamples - 1);
        bool ok = false;
        const double sy = f(sx, &ok);
        if (!ok) {
            havePrev = false;
            continue;
        }
        if (sy == 0.0) {
            finish(true, sx);
            return result;
        }
        if (havePrev && ((prevY < 0.0) != (sy < 0.0))) {
            double lo = prevX, hi = sx, flo = prevY;
            for (int b = 0; b < 200; ++b) {
                const double mid = 0.5 * (lo + hi);
                bool okm = false;
                const double fm = f(mid, &okm);
                if (!okm)
                    break;
                if ((flo < 0.0) != (fm < 0.0)) {
                    hi = mid;
                } else {
                    lo = mid;
                    flo = fm;
                }
                if (std::fabs(hi - lo) < 1e-14 * std::max(1.0, std::fabs(lo)))
                    break;
            }
            finish(true, 0.5 * (lo + hi));
            return result;
        }
        prevX = sx;
        prevY = sy;
        havePrev = true;
    }

    finish(false, 0.0);
    return result;
}

// ---------------------------------------------------------------------------

bool Engine::historyPrev()
{
    if (m_history.isEmpty())
        return false;
    if (m_historyPos < 0)
        m_historyPos = m_history.size();
    if (m_historyPos == 0)
        return false;
    --m_historyPos;
    m_root = m_history.at(m_historyPos).expression->clone();
    m_cursor = Cursor{ m_root.get(), m_root->childCount() };
    emit stateChanged();
    return true;
}

bool Engine::historyNext()
{
    if (m_history.isEmpty() || m_historyPos < 0)
        return false;
    if (m_historyPos + 1 >= m_history.size()) {
        m_historyPos = -1;
        m_root = Node::makeRow();
        m_cursor = Cursor{ m_root.get(), 0 };
        emit stateChanged();
        return true;
    }
    ++m_historyPos;
    m_root = m_history.at(m_historyPos).expression->clone();
    m_cursor = Cursor{ m_root.get(), m_root->childCount() };
    emit stateChanged();
    return true;
}

// ---------------------------------------------------------------------------

void Engine::setVariable(const QString &name, const Value &v)
{
    m_ctx.vars[name] = v;
    emit stateChanged();
}

void Engine::memoryAdd(double delta)
{
    const double cur = m_ctx.vars.value(QStringLiteral("M")).real().d;
    m_ctx.vars[QStringLiteral("M")] = Value(Real(cur + delta));
    emit stateChanged();
}

bool Engine::memoryActive() const
{
    const Value m = m_ctx.vars.value(QStringLiteral("M"));
    return m.isReal() && m.real().d != 0.0;
}

void Engine::clearMemory()
{
    m_ctx.vars[QStringLiteral("M")] = Value(Real(0.0, Exact::rational(0)));
    emit stateChanged();
}

void Engine::clearVariables()
{
    const QStringList names = { QStringLiteral("A"), QStringLiteral("B"), QStringLiteral("C"),
                                QStringLiteral("D"), QStringLiteral("E"), QStringLiteral("F"),
                                QStringLiteral("x"), QStringLiteral("y"), QStringLiteral("z"),
                                QStringLiteral("M") };
    for (const QString &n : names)
        m_ctx.vars[n] = Value(Real(0.0, Exact::rational(0)));
    emit stateChanged();
}

} // namespace fx

#include "Node.h"

#include <QHash>
#include <QSet>

namespace fx {

Node::Node(NodeKind kind, QString code)
    : m_kind(kind), m_code(std::move(code))
{
}

NodeP Node::makeRow()
{
    return std::make_unique<Node>(NodeKind::Row);
}

NodeP Node::makeAtom(const QString &code)
{
    return std::make_unique<Node>(NodeKind::Atom, code);
}

NodeP Node::makeStructure(NodeKind kind, int argCount)
{
    auto n = std::make_unique<Node>(kind);
    for (int i = 0; i < argCount; ++i) {
        auto row = makeRow();
        row->m_parent = n.get();
        n->m_args.push_back(std::move(row));
    }
    return n;
}

QVector<Node *> Node::children() const
{
    QVector<Node *> out;
    out.reserve(childCount());
    for (const auto &c : m_children)
        out.append(c.get());
    return out;
}

void Node::insertChild(int index, NodeP child)
{
    child->m_parent = this;
    const int at = qBound(0, index, childCount());
    m_children.insert(m_children.begin() + at, std::move(child));
}

NodeP Node::takeChild(int index)
{
    if (index < 0 || index >= childCount())
        return nullptr;
    NodeP n = std::move(m_children[index]);
    m_children.erase(m_children.begin() + index);
    if (n)
        n->m_parent = nullptr;
    return n;
}

int Node::indexInParent() const
{
    if (!m_parent)
        return -1;
    for (int i = 0; i < m_parent->childCount(); ++i)
        if (m_parent->m_children[i].get() == this)
            return i;
    for (int i = 0; i < m_parent->argCount(); ++i)
        if (m_parent->m_args[i].get() == this)
            return i;
    return -1;
}

NodeP Node::clone() const
{
    auto n = std::make_unique<Node>(m_kind, m_code);
    for (const auto &c : m_children) {
        auto cc = c->clone();
        cc->m_parent = n.get();
        n->m_children.push_back(std::move(cc));
    }
    for (const auto &a : m_args) {
        auto aa = a->clone();
        aa->m_parent = n.get();
        n->m_args.push_back(std::move(aa));
    }
    return n;
}

bool Node::isOperandEnd() const
{
    if (isStructure())
        return true;
    if (!isAtom())
        return false;
    const QString &c = m_code;
    return atomIsDigit(c) || atomIsValue(c) || atomIsPostfix(c) || c == QLatin1String(")");
}

QString Node::toLinear() const
{
    switch (m_kind) {
    case NodeKind::Row: {
        QString s;
        for (const auto &c : m_children)
            s += c->toLinear();
        return s;
    }
    case NodeKind::Atom:
        return atomGlyph(m_code);
    case NodeKind::Frac:
        return QStringLiteral("(%1)/(%2)").arg(arg(0)->toLinear(), arg(1)->toLinear());
    case NodeKind::MixedFrac:
        return QStringLiteral("%1(%2)/(%3)")
                .arg(arg(0)->toLinear(), arg(1)->toLinear(), arg(2)->toLinear());
    case NodeKind::Power:
        return QStringLiteral("^(%1)").arg(arg(0)->toLinear());
    case NodeKind::Sqrt:
        return QStringLiteral("√(%1)").arg(arg(0)->toLinear());
    case NodeKind::Root:
        return QStringLiteral("(%1)√(%2)").arg(arg(0)->toLinear(), arg(1)->toLinear());
    case NodeKind::LogBase:
        return QStringLiteral("log(%1,%2)").arg(arg(0)->toLinear(), arg(1)->toLinear());
    case NodeKind::Abs:
        return QStringLiteral("Abs(%1)").arg(arg(0)->toLinear());
    case NodeKind::Sum:
        return QStringLiteral("Σ(%1,%2,%3)")
                .arg(arg(0)->toLinear(), arg(1)->toLinear(), arg(2)->toLinear());
    case NodeKind::Product:
        return QStringLiteral("Π(%1,%2,%3)")
                .arg(arg(0)->toLinear(), arg(1)->toLinear(), arg(2)->toLinear());
    case NodeKind::Integral:
        return QStringLiteral("∫(%1,%2,%3)")
                .arg(arg(0)->toLinear(), arg(1)->toLinear(), arg(2)->toLinear());
    case NodeKind::Derivative:
        return QStringLiteral("d/dx(%1,%2)").arg(arg(0)->toLinear(), arg(1)->toLinear());
    case NodeKind::Recurring:
        return QStringLiteral("[%1]").arg(arg(0)->toLinear());
    }
    return QString();
}

// ---------------------------------------------------------------------------

bool atomIsDigit(const QString &code)
{
    return code.size() == 1 && code.at(0).isDigit();
}

bool atomIsFunction(const QString &code)
{
    return code.endsWith(QLatin1Char('('));
}

bool atomIsPostfix(const QString &code)
{
    static const QSet<QString> set = {
        QStringLiteral("!"),    QStringLiteral("sqr"),  QStringLiteral("cube"),
        QStringLiteral("inv"),  QStringLiteral("deg"),  QStringLiteral("rad"),
        QStringLiteral("grad"), QStringLiteral("pct"),  QStringLiteral("T")
    };
    return set.contains(code);
}

bool atomIsInfix(const QString &code)
{
    static const QSet<QString> set = {
        QStringLiteral("+"),   QStringLiteral("-"),   QStringLiteral("*"),
        QStringLiteral("/"),   QStringLiteral("nPr"), QStringLiteral("nCr"),
        QStringLiteral("angle"), QStringLiteral("and"), QStringLiteral("or"),
        QStringLiteral("xor"), QStringLiteral("xnor"), QStringLiteral("->"),
        QStringLiteral("=")
    };
    return set.contains(code);
}

bool atomIsValue(const QString &code)
{
    static const QSet<QString> set = {
        QStringLiteral("pi"), QStringLiteral("e"), QStringLiteral("i"),
        QStringLiteral("Ran#"), QStringLiteral("A"), QStringLiteral("B"),
        QStringLiteral("C"), QStringLiteral("D"), QStringLiteral("E"),
        QStringLiteral("F"), QStringLiteral("x"), QStringLiteral("y"),
        QStringLiteral("z"), QStringLiteral("M"), QStringLiteral("Ans"),
        QStringLiteral("PreAns"), QStringLiteral("MatA"), QStringLiteral("MatB"),
        QStringLiteral("MatC"), QStringLiteral("MatD"), QStringLiteral("MatAns"),
        QStringLiteral("VctA"), QStringLiteral("VctB"), QStringLiteral("VctC"),
        QStringLiteral("VctD"), QStringLiteral("VctAns")
    };
    return set.contains(code);
}

QString atomGlyph(const QString &code)
{
    static const QHash<QString, QString> glyphs = {
        { QStringLiteral("*"),      QStringLiteral("×") },
        { QStringLiteral("/"),      QStringLiteral("÷") },
        { QStringLiteral("-"),      QStringLiteral("−") },
        { QStringLiteral("neg"),    QStringLiteral("−") },
        { QStringLiteral("E"),      QStringLiteral("ᴇ") },
        { QStringLiteral("pi"),     QStringLiteral("π") },
        { QStringLiteral("sqr"),    QStringLiteral("²") },
        { QStringLiteral("cube"),   QStringLiteral("³") },
        { QStringLiteral("inv"),    QStringLiteral("⁻¹") },
        { QStringLiteral("deg"),    QStringLiteral("°") },
        { QStringLiteral("rad"),    QStringLiteral("ʳ") },
        { QStringLiteral("grad"),   QStringLiteral("ᵍ") },
        { QStringLiteral("pct"),    QStringLiteral("%") },
        { QStringLiteral("T"),      QStringLiteral("ᵀ") },
        { QStringLiteral("angle"),  QStringLiteral("∠") },
        { QStringLiteral("->"),     QStringLiteral("→") },
        { QStringLiteral("and"),    QStringLiteral("and") },
        { QStringLiteral("or"),     QStringLiteral("or") },
        { QStringLiteral("xor"),    QStringLiteral("xor") },
        { QStringLiteral("xnor"),   QStringLiteral("xnor") },
    };
    auto it = glyphs.constFind(code);
    if (it != glyphs.constEnd())
        return it.value();
    return code;
}

} // namespace fx

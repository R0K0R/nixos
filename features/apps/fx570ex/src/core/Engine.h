#pragma once
#include "Eval.h"
#include "Format.h"
#include "Node.h"
#include "Value.h"

#include <QObject>
#include <QVector>

namespace fx {

struct HistoryEntry {
    // shared, not unique: QList requires its elements to be copyable
    std::shared_ptr<Node> expression;
    QString resultText;
    QString altText;      // the other half of the S<=>D pair, empty when there is none
    Value result;
};

// Owns the edited expression, the cursor, the settings and the variable store.
// The UI talks to this and never touches the tree directly.
class Engine : public QObject {
    Q_OBJECT
public:
    explicit Engine(QObject *parent = nullptr);

    // --- editing ---------------------------------------------------------
    void insertAtom(const QString &code);
    void insertStructure(NodeKind kind);
    void insertText(const QString &literal); // convenience: each char as an atom
    bool backspace();
    void clearEntry();
    void clearAll();

    bool moveLeft();
    bool moveRight();
    bool moveUp();
    bool moveDown();
    void moveHome();
    void moveEnd();

    const Node *root() const { return m_root.get(); }
    const Node *cursorRow() const { return m_cursor.row; }
    int cursorIndex() const { return m_cursor.index; }
    bool isEmpty() const { return m_root->childCount() == 0; }

    // --- evaluation ------------------------------------------------------
    bool execute();                     // true on success
    void toggleStandardDecimal();

    QString resultText() const { return m_resultText; }
    QString errorText() const { return m_errorText; }
    bool hasResult() const { return m_hasResult; }
    bool hasAlternateForm() const { return !m_altText.isEmpty(); }
    const Value &lastResult() const { return m_lastResult; }

    /*
      SOLVE (SHIFT+CALC). Finds a root of the entered expression: `left = right`
      becomes left - right, and an expression with no `=` is taken as `expr = 0`,
      which is what the manual specifies.

      The solution is written back into the variable, the way the real unit
      leaves X holding the answer.
    */
    struct SolveResult {
        bool ok = false;
        QString variable;
        double value = 0.0;
        double residual = 0.0;   // the unit's "L-R", how close the sides came
        QString error;
    };
    SolveResult solveForVariable(const QString &preferred = QString());

    // Unknowns appearing in the current entry, in A-F, x, y, z, M order.
    QStringList entryVariables() const;

    // --- history ---------------------------------------------------------
    bool historyPrev();                 // load the previous entry into the editor
    bool historyNext();
    const QVector<HistoryEntry> &history() const { return m_history; }

    // --- state -----------------------------------------------------------
    AngleUnit angleUnit() const { return m_ctx.angle; }
    void setAngleUnit(AngleUnit u) { m_ctx.angle = u; emit stateChanged(); }
    bool complexMode() const { return m_ctx.complexMode; }
    void setComplexMode(bool on) { m_ctx.complexMode = on; emit stateChanged(); }

    FormatOptions formatOptions() const { return m_fmt; }
    void setFormatOptions(const FormatOptions &f) { m_fmt = f; emit stateChanged(); }

    Value variable(const QString &name) const { return m_ctx.vars.value(name); }
    void setVariable(const QString &name, const Value &v);
    void memoryAdd(double delta);
    bool memoryActive() const;
    void clearMemory();
    void clearVariables();

signals:
    void stateChanged();

private:
    Node *ensureRow(Node *n);
    void placeCursor(Node *row, int index);
    bool stepOutLeft();
    bool stepOutRight();
    void rebuildResultStrings(const Value &v);

    NodeP m_root;
    Cursor m_cursor;

    Context m_ctx;
    FormatOptions m_fmt;

    QVector<HistoryEntry> m_history;
    int m_historyPos = -1;

    Value m_lastResult;
    QString m_resultText;
    QString m_altText;
    QString m_errorText;
    bool m_hasResult = false;
    bool m_showingAlternate = false;
};

} // namespace fx

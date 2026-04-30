# Respaldo Matemático: Proyecto 2 - Álgebra de Matrices en ARM64

Este documento detalla el fundamento matemático de las operaciones implementadas en el proyecto, utilizando como ejemplo las matrices proporcionadas durante las pruebas.

## Matrices de Ejemplo
Para todos los casos, utilizaremos:
- **Matriz A:**
  $$A = \begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}$$
- **Matriz B:**
  $$B = \begin{pmatrix} 4 & 3 \\ 2 & 1 \end{pmatrix}$$

---

## 1. Identidad de A
**Concepto:** Genera una matriz cuadrada $R$ del mismo tamaño que $A$ donde la diagonal principal contiene 1s y el resto 0s.
- **Resultado:**
  $$R = \begin{pmatrix} 1 & 0 \\ 0 & 1 \end{pmatrix}$$

## 2. Transpuesta de A ($A^T$)
**Concepto:** Se intercambian filas por columnas. El elemento en la posición $(i, j)$ de $A$ pasa a la posición $(j, i)$ en $R$.
- **Cálculo:**
  - Fila 1 de A $[1, 2]$ se convierte en Columna 1 de R.
  - Fila 2 de A $[3, 4]$ se convierte en Columna 2 de R.
- **Resultado:**
  $$R = \begin{pmatrix} 1 & 3 \\ 2 & 4 \end{pmatrix}$$

## 3. Suma ($A + B$)
**Concepto:** Suma elemento a elemento ($a_{ij} + b_{ij}$).
- **Cálculo:**
  - $1 + 4 = 5$
  - $2 + 3 = 5$
  - $3 + 2 = 5$
  - $4 + 1 = 5$
- **Resultado:**
  $$R = \begin{pmatrix} 5 & 5 \\ 5 & 5 \end{pmatrix}$$

## 4. Resta ($A - B$)
**Concepto:** Resta elemento a elemento ($a_{ij} - b_{ij}$).
- **Cálculo:**
  - $1 - 4 = -3$
  - $2 - 3 = -1$
  - $3 - 2 = 1$
  - $4 - 1 = 3$
- **Resultado:**
  $$R = \begin{pmatrix} -3 & -1 \\ 1 & 3 \end{pmatrix}$$

## 5. Multiplicación Matricial ($A \times B$)
**Concepto:** Producto punto de las filas de $A$ por las columnas de $B$.
- **Cálculo:**
  - $R_{11} = (1 \times 4) + (2 \times 2) = 4 + 4 = 8$
  - $R_{12} = (1 \times 3) + (2 \times 1) = 3 + 2 = 5$
  - $R_{21} = (3 \times 4) + (4 \times 2) = 12 + 8 = 20$
  - $R_{22} = (3 \times 3) + (4 \times 1) = 9 + 4 = 13$
- **Resultado:**
  $$R = \begin{pmatrix} 8 & 5 \\ 20 & 13 \end{pmatrix}$$

## 6. Gauss (Triangular Superior)
**Concepto:** Eliminar los elementos debajo de la diagonal principal para facilitar cálculos como el determinante.
- **Operación:** Fila 2 = Fila 2 - ($3 \times$ Fila 1).
  - Elemento (2,1): $3 - (3 \times 1) = 0$
  - Elemento (2,2): $4 - (3 \times 2) = -2$
- **Resultado:**
  $$R = \begin{pmatrix} 1 & 2 \\ 0 & -2 \end{pmatrix}$$

## 7. Gauss-Jordan (Forma Reducida)
**Concepto:** Llevar la matriz a su forma escalonada reducida (identidad si el determinante es distinto de cero).
- **Pasos simplificados:**
  1. Normalizar pivote de Fila 2 (dividir entre -2).
  2. Eliminar el valor sobre el pivote en Fila 1.
- **Resultado:**
  $$R = \begin{pmatrix} 1 & 0 \\ 0 & 1 \end{pmatrix}$$

## 8. Determinante ($|A|$)
**Concepto:** Valor escalar que define propiedades de la matriz. Para una 2x2: $(a_{11} \times a_{22}) - (a_{12} \times a_{21})$.
- **Cálculo:**
  - $(1 \times 4) - (2 \times 3) = 4 - 6 = -2$
- **Resultado:** $-2$
/*
 * This code was originally created by **Elias de Almeida Ramos**
 * for 2D point clustering. It is used here as part of the reference
 * model generator for the entropy-based 2D clustering pipeline.
 */

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>

#define INITIAL_CAPACITY 2000

int main() {
    // --- 1. INGESTÃO DE DADOS (X, Y) ---
    printf("--- L.E.G.I.A.O. V3 [MODO 2D]: PROCESSANDO MAPA PLANAR ---\n");

    FILE *file = fopen("../data/cluster.txt", "r");
    if (file == NULL) {
        printf("Erro na leitura: Nao foi possivel abrir o arquivo cluster.txt\n");
        return 1;
    }

    int capacity = INITIAL_CAPACITY;
    double *X = (double *)malloc(capacity * sizeof(double));
    double *Y = (double *)malloc(capacity * sizeof(double));
    int n_total = 0;

    double val1, val2;
    while (fscanf(file, "%lf %lf%*[^\n]", &val1, &val2) == 2) {
        if (n_total >= capacity) {
            capacity *= 2;
            X = (double *)realloc(X, capacity * sizeof(double));
            Y = (double *)realloc(Y, capacity * sizeof(double));
        }
        X[n_total] = val1;
        Y[n_total] = val2;
        n_total++;
    }
    fclose(file);

    if (n_total == 0) {
        printf("Erro: Nenhum dado valido carregado.\n");
        free(X); free(Y);
        return 1;
    }

    printf("Sucesso: %d pontos carregados para processamento 2D.\n", n_total);

    // Alocação dos vetores dinâmicos pós-ingestão
    double *X_f = (double *)malloc(n_total * sizeof(double));
    double *Y_f = (double *)malloc(n_total * sizeof(double));
    double *H = (double *)malloc(n_total * sizeof(double));
    double *grad_x = (double *)malloc(n_total * sizeof(double));
    double *grad_y = (double *)malloc(n_total * sizeof(double));
    double *forca = (double *)malloc(n_total * sizeof(double));

    for (int i = 0; i < n_total; i++) {
        X_f[i] = X[i];
        Y_f[i] = Y[i];
    }

    // Alocação correta da Matriz P (Matricial bidimensional dinâmico)
    double **P = (double **)malloc(n_total * sizeof(double *));
    for (int i = 0; i < n_total; i++) {
        P[i] = (double *)malloc(n_total * sizeof(double));
    }

    // --- 2. MOTOR L.E.G.I.A.O. 2D (FLUXO DE RICCI PLANAR MATRICIAL) ---
    double T = 1.003;
    double alpha = 1.028;
    double limiar_cirurgico = 7.7; // 0.93
    int max_iter = 50;

    clock_t start_time = clock();
    printf("--- EXECUTANDO COLAPSO DE RICCI 2D ---\n");

    for (int step = 0; step < max_iter; step++) {
        
        // Passo A: Matriz de distâncias D2 e cálculo do Kernel Gaussiano P
        for (int i = 0; i < n_total; i++) {
            double sum_row_P = 0.0;
            for (int j = 0; j < n_total; j++) {
                double dx = X_f[i] - X_f[j];
                double dy = Y_f[i] - Y_f[j];
                double D2_ij = (dx * dx) + (dy * dy);
                
                P[i][j] = exp(-D2_ij / (2.0 * T * T));
                sum_row_P += P[i][j];
            }

            // Normalização idêntica ao MATLAB: P = P ./ (sum(P, 2) + 1e-12)
            H[i] = 0.0;
            for (int j = 0; j < n_total; j++) {
                P[i][j] /= (sum_row_P + 1e-12);
                H[i] -= P[i][j] * log2(P[i][j] + 1e-12); // Cálculo da Entropia H
            }
        }

        // Passo B: Gradientes de Ricci e Atualização das Posições
        for (int i = 0; i < n_total; i++) {
            double P_dot_X = 0.0;
            double P_dot_Y = 0.0;
            for (int j = 0; j < n_total; j++) {
                P_dot_X += P[i][j] * X_f[j];
                P_dot_Y += P[i][j] * Y_f[j];
            }

            grad_x[i] = P_dot_X - X_f[i];
            grad_y[i] = P_dot_Y - Y_f[i];

            // Cirurgia de Perelman baseada no limiar de Entropia
            forca[i] = 0.35;
            if (H[i] > limiar_cirurgico) {
                forca[i] = 0.002;
            }
        }

        // Atualização síncrona dos pontos para evitar distorções de iteração histórica
        for (int i = 0; i < n_total; i++) {
            X_f[i] += forca[i] * grad_x[i];
            Y_f[i] += forca[i] * grad_y[i];
        }

        T *= alpha;
    }

    clock_t end_time = clock();
    double t_calc = (double)(end_time - start_time) / CLOCKS_PER_SEC;

    // --- 3. AGRUPAMENTO GEOMÉTRICO FINAL ---
    int *cluster_labels = (int *)malloc(n_total * sizeof(int));
    for (int i = 0; i < n_total; i++) cluster_labels[i] = -1;

    int num_clusters = 0;
    // Tolerância adaptada para varrer o mapa físico preservando os lóbulos independentes
    double tol = 1.25; 

    for (int i = 0; i < n_total; i++) {
        if (cluster_labels[i] != -1) continue;

        cluster_labels[i] = num_clusters;

        for (int j = i + 1; j < n_total; j++) {
            if (cluster_labels[j] == -1) {
                double dx = X_f[i] - X_f[j];
                double dy = Y_f[i] - Y_f[j];
                double dist = sqrt(dx * dx + dy * dy);

                if (dist <= tol) {
                    cluster_labels[j] = num_clusters;
                }
            }
        }
        num_clusters++;
    }

    int *cluster_sizes = (int *)calloc(num_clusters, sizeof(int));
    for (int i = 0; i < n_total; i++) {
        cluster_sizes[cluster_labels[i]]++;
    }

    // --- 4. RELATÓRIO DE SAÍDA REALISTA ---
    printf("------------------------------------------------------------------\n");
    printf("L.E.G.I.A.O. 2D: Filamentos Revelados com sucesso (%.2fs)\n", t_calc);
    printf("------------------------------------------------------------------\n");
    
    int thresh = 5; // Ignora ruído menor do que 5 pontos dispersos
    int real_clusters_count = 0;
    int noise_points = 0;

    for (int c = 0; c < num_clusters; c++) {
        if (cluster_sizes[c] >= thresh) real_clusters_count++;
    }

    printf(">> TOTAL DE CLUSTERS DETECTADOS NA TEIA COSMOLÓGICA: %d <<\n", real_clusters_count);
    printf("------------------------------------------------------------------\n");
    printf("Métricas Finais de População de Nós:\n");

    int id_exibicao = 1;
    for (int c = 0; c < num_clusters; c++) {
        if (cluster_sizes[c] >= thresh) {
            printf("  * Macro-Estrutura #%02d: %d galáxias/pontos (%.1f%% do mapa)\n", 
                   id_exibicao++, cluster_sizes[c], ((double)cluster_sizes[c] / n_total) * 100.0);
        } else {
            noise_points += cluster_sizes[c];
        }
    }

    if (noise_points > 0) {
        printf("  * Filamentos difusos/Ruído orbital: %d pontos dispersos\n", noise_points);
    }
    printf("------------------------------------------------------------------\n");

    // Liberação de memória
    free(X); free(Y); free(X_f); free(Y_f); 
    free(H); free(grad_x); free(grad_y); free(forca);
    free(cluster_labels); free(cluster_sizes);
    for (int i = 0; i < n_total; i++) {
        free(P[i]);
    }
    free(P);

    return 0;
}
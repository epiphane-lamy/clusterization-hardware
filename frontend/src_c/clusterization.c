#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>
#include <stdint.h>
#include <string.h>

#define INITIAL_CAPACITY 2000
#define LUT_SIZE 10241

#define TB_FILE "../tb/clusterization_tb.sv"
#define BENCHMARK_FILE "../data/cluster1.txt"
#define SCRIPT_FILE "../scripts/plot_benchmark.sh"

void update_plot_script(void)
{
    FILE *input = fopen(SCRIPT_FILE, "r");
    if (input == NULL) {
        perror("Erreur ouverture script");
        return;
    }

    FILE *output = fopen("../scripts/plot_benchmark.tmp", "w");
    if (output == NULL) {
        perror("Erreur création fichier temporaire");
        fclose(input);
        return;
    }

    char line[2048];
    int found = 0;

    while (fgets(line, sizeof(line), input)) {

        // Cherche une ligne qui commence par BENCHMARK_FILE=
        if (strncmp(line, "BENCHMARK_FILE=", strlen("BENCHMARK_FILE=")) == 0) {

            // Remplace toute la ligne
            fprintf(output, "BENCHMARK_FILE=\"%s\"\n", BENCHMARK_FILE);

            found = 1;
        }
        else {
            // Copie les autres lignes sans modification
            fputs(line, output);
        }
    }

    fclose(input);
    fclose(output);

    if (!found) {
        printf("Attention : BENCHMARK_FILE= non trouve dans %s\n",
               SCRIPT_FILE);

        remove("../scripts/plot_benchmark.tmp");
        return;
    }

    // Remplace l'ancien script
    if (remove(SCRIPT_FILE) != 0) {
        perror("Erreur suppression ancien script");
        remove("../scripts/plot_benchmark.tmp");
        return;
    }

    if (rename("../scripts/plot_benchmark.tmp", SCRIPT_FILE) != 0) {
        perror("Erreur renommage script");
        return;
    }

    printf("BENCHMARK_FILE mis a jour : %s\n", BENCHMARK_FILE);
}
int main() {
    update_plot_script();
    uint16_t exp_lut[LUT_SIZE];

    //FILE *f_exp_LUT = fopen("../data/exp_lut.hex","w");
    
    for(int i=0;i<LUT_SIZE;i++)
    {
        // reconstruction de l'argument réel
        float arg = -10.0f + ((float)i / 1024.0f); //divise par 1024 car format q6.10

        // exponentielle réelle
        float y = expf(arg);

        float q = y * 65536.0f;

        if (q > 65535.0f)
            q = 65535.0f;

        exp_lut[i] = (uint16_t)q;
    }

    printf("exp_lut[0]     = %u\n", exp_lut[0]);       // exp(-10)
    printf("exp_lut[1]     = %u\n", exp_lut[1]);
    printf("exp_lut[5356]     = %u\n", exp_lut[5356]);
    printf("exp_lut[10240] = %u\n", exp_lut[10240]);   // exp(0)

    //fclose(f_exp_LUT);


    uint32_t inv[1024];
    uint32_t result_inv;

    FILE *f_inv_LUT = fopen("../data/inv_lut.hex","w");

    for(int i=0;i<1024;i++)
    {
        double m = 1.0 + ((double)i / 1024.0);

        result_inv = (uint32_t)((1.0 / m) * 65536.0);
        if (result_inv > 65535)
            result_inv = 65535;

        fprintf(f_inv_LUT, "%04X\n", result_inv);

        inv[i] = result_inv;
    }
    fclose(f_inv_LUT);

    // --- 1. DATA INGESTION (X, Y) ---
    printf("--- L.E.G.I.A.O. V3 [2D MODE]: PROCESSING PLANAR MAP ---\n");

    FILE *file = fopen(BENCHMARK_FILE, "r");
    if (file == NULL) {
        printf("Error while opening the file cluster.txt\n");
        return 1;
    }

    int capacity = INITIAL_CAPACITY;
    double *X = (double *)malloc(capacity * sizeof(double));
    double *Y = (double *)malloc(capacity * sizeof(double));
    int n_total = 0;

    double val1, val2;
    while (fscanf(file, "%lf %lf%*[^\n]", &val1, &val2) == 2) {
    //while (n_total < 100 && fscanf(file, "%lf %lf%*[^\n]", &val1, &val2) == 2) {
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

    // ================================================================
    // Normalisation 
    float x_min = X[0], x_max = X[0];
    float y_min = Y[0], y_max = Y[0];

    for (int i = 1; i < n_total; i++) {
        if (X[i] < x_min) x_min = X[i];
        if (X[i] > x_max) x_max = X[i];

        if (Y[i] < y_min) y_min = Y[i];
        if (Y[i] > y_max) y_max = Y[i];
    }

    float center_x = (x_min + x_max) * 0.5f;
    float center_y = (y_min + x_max) * 0.5f;

    float rangex = x_max - x_min;
    float rangey = y_max - y_min;

    float range_n = (rangex > rangey) ? rangex : rangey;

    float norm_scale = 2.0f / range_n;

    for (int i = 0; i < n_total; i++) {
        X[i] = (X[i] - center_x) * norm_scale;
        Y[i] = (Y[i] - center_y) * norm_scale;
    }

    // ================================================================


    FILE *in = fopen(TB_FILE, "r");
    if (!in) {
        perror("Impossible d'ouvrir le testbench");
        return 1;
    }

    FILE *out = fopen("../tb/clusterization_tb.tmp", "w");
    if (!out) {
        perror("Impossible de créer le fichier temporaire");
        fclose(in);
        return 1;
    }

    char line[1024];

    while (fgets(line, sizeof(line), in)) {
        if (strstr(line, "parameter int NB_POINTS")) {
            fprintf(out, "    parameter int NB_POINTS    = %d,        // Number of points\n", n_total);
        } else {
            fputs(line, out);
        }
    }

    fclose(in);
    fclose(out);

    if (remove(TB_FILE) != 0) {
        perror("Impossible de supprimer l'ancien testbench");
        return 1;
    }

    if (rename("../tb/clusterization_tb.tmp", TB_FILE) != 0) {
        perror("Impossible de renommer le fichier temporaire");
        return 1;
    }

    printf("TB mis a jour : NB_POINTS = %d\n", n_total);




    printf("/////////// N_total = %d\n", n_total);

    if (n_total == 0) {
        printf("Error: No valid data loaded.\n");
        free(X); free(Y);
        return 1;
    }

    printf("Success: %d points loaded for 2D processing.\n", n_total);

    // Allocation of dynamic vectors after ingestion
    double *X_float = (double *)malloc(n_total * sizeof(double));
    double *Y_float = (double *)malloc(n_total * sizeof(double));
    int32_t *X_f = (int32_t *)malloc(n_total * sizeof(int32_t));
    int32_t *Y_f = (int32_t *)malloc(n_total * sizeof(int32_t));

    // Entropy
    double *H = (double *)malloc(n_total * sizeof(double));
    int32_t *H_fixed = (int32_t *)malloc(n_total * sizeof(int32_t));

    // Gradient
    double *grad_x_float = (double *)malloc(n_total * sizeof(double));
    double *grad_y_float = (double *)malloc(n_total * sizeof(double));
    int32_t *grad_x = (int32_t *)malloc(n_total * sizeof(int32_t));
    int32_t *grad_y = (int32_t *)malloc(n_total * sizeof(int32_t));

    // force 
    double *forca_float = (double *)malloc(n_total * sizeof(double));
    int32_t *forca = (int32_t *)malloc(n_total * sizeof(int32_t));
    
    float xmin = X[0], xmax = X[0];
    float ymin = Y[0], ymax = Y[0];

    for (int i = 1; i < n_total; i++) {
        if (X[i] < xmin) xmin = X[i];
        if (X[i] > xmax) xmax = X[i];

        if (Y[i] < ymin) ymin = Y[i];
        if (Y[i] > ymax) ymax = Y[i];
    }
    printf("xmin=%f\n", xmin);
    printf("ymin=%f\n", ymin);
    float range_x = xmax - xmin;
    float range_y = ymax - ymin;

    // On prend la plus grande plage pour conserver le ratio X/Y
    float range = (range_x > range_y) ? range_x : range_y;

    float scale_points = 255.0f / range;

    printf("range = %f\n", range);
    printf("scale = %f\n", 255.0f/range);
    printf("scale² = %f\n", (255.0f/range)*(255.0f/range));

    uint8_t *X_q = malloc(n_total * sizeof(uint8_t));
    uint8_t *Y_q = malloc(n_total * sizeof(uint8_t));

    for (int i = 0; i < n_total; i++) {
        X_q[i] = (uint8_t)roundf((X[i] - xmin) * scale_points);
        Y_q[i] = (uint8_t)roundf((Y[i] - ymin) * scale_points);
    }

    for (int i = 0; i < n_total; i++) {
        X_float[i] = X[i];
        Y_float[i] = Y[i];
        X_f[i] = ((int16_t)X_q[i]) << 8;
        Y_f[i] = ((int16_t)Y_q[i]) << 8;
    }

    FILE *f_fixed = fopen("../data/cluster_fixed_full_benchmark.txt", "w");
    if (f_fixed == NULL) {
        printf("Erreur lors de l'ouverture de cluster_fixed.txt\n");
        return 1;
    }

    fprintf(f_fixed, "%f %f %f %f %f %f\n", scale_points, xmin, ymin, norm_scale, center_x, center_y);
    for (int i = 0; i < n_total; i++) {
        fprintf(f_fixed, "%d %d\n", X_f[i], Y_f[i]);
    }

    fclose(f_fixed);



    // Correct allocation of the P matrix (dynamic two-dimensional matrix)
    double **P_float = (double **)malloc(n_total * sizeof(double *));
    uint16_t **P = (uint16_t **)malloc(n_total * sizeof(uint16_t *));
    for (int i = 0; i < n_total; i++) {
        P_float[i] = (double *)malloc(n_total * sizeof(double));
        P[i] = (uint16_t *)malloc(n_total * sizeof(uint16_t));
    }

    // --- 2. L.E.G.I.A.O. 2D ENGINE (MATRIX PLANAR RICCI FLOW) ---
    double T_float = 1.003;
    //double T = 23.87;
    //double T = scale_points * T_float;
    uint32_t T_q8_8 = (uint32_t)(scale_points * T_float * 256.0);
    double T_real = T_q8_8 / 256.0;
    printf("--- valeur de T fixed --- %f\n", T_real);
    
    double alpha_float = 1.028;
    uint32_t alpha = (uint32_t)(1.028 * 65536);
    //double alpha = 1.02;


    //double limiar_cirurgico = 0.93;
    double limiar_cirurgico = 7.7;
    uint32_t limiar_cirurgico_fixed = 65200;
    int max_iter = 50;

    clock_t start_time = clock();
    printf("--- EXECUTANDO COLAPSO DE RICCI 2D ---\n");
    double global_min_arg = 1e9;
    double global_max_arg = -1e9;

    long count_pass_exp = 0;
    long count_positive = 0;
    long count_arg_1 = 0;
    long count_arg_2 = 0;
    long count_arg_3 = 0;
    long count_arg_4 = 0;
    long count_arg_5 = 0;
    long count_arg_6 = 0;
    long count_arg_7 = 0;
    long count_arg_8 = 0;

    long lost = 0;
    double sum_row_P_min = 1000000;
    double sum_row_P_max = 0;

    int32_t min_H = 100000;
    int32_t max_H = 0;
    int32_t max_X_f = 0;
    int32_t min_X_f = 100000;
    int32_t min_mult_act_X = 100000;
    int32_t max_mult_act_X = 0;
    int32_t max_mult_act_Y = 0;
    int32_t min_mult_act_Y = 100000;
    long count_H_1 = 0;
    long count_H_2 = 0;
    long count_H_3 = 0;
    long count_H_4 = 0;
    long count_H_5 = 0;
    long count_H_6 = 0;
    long count_H_7 = 0;
    long count_H_8 = 0;

    long count_Hf_1 = 0;
    long count_Hf_2 = 0;
    long count_Hf_3 = 0;
    long count_Hf_4 = 0;
    long count_Hf_5 = 0;
    long count_Hf_6 = 0;
    long count_Hf_7 = 0;
    long count_Hf_8 = 0;

    //FILE *f_P_ij_fixed = fopen("../data/P_ij_fixed.txt", "w");
    FILE *f_hex = fopen("../data/k_step_rom.hex", "w");
    //FILE *f_act = fopen("../data/mult_act_fixed.txt", "w");

    for (int step = 0; step < max_iter; step++) {
        double K_float = 1.0 / (2.0 * T_real * T_real);

        uint16_t K_fixed = (uint16_t)(K_float * 65536.0);
        fprintf(f_hex, "%04X\n", (uint16_t)-K_fixed);

        //printf("T=%f K=%f K_fixed=%u\n", T_real, K_float, K_fixed);

        int16_t K_fixed_signed = -(int16_t)K_fixed;
        //printf("T=%f K=%f K_fixed=%u (-K_fixed=%d / 0x%04X)\n",  T_real, K_float, K_fixed, K_fixed_signed, (uint16_t)K_fixed_signed);

        
        double max_error = 0;
        // Step A: Distance matrix D2 and Gaussian kernel P calculation
        for (int i = 0; i < n_total; i++) {
            double sum_row_P_float = 0.0;
            uint32_t sum_row_P = 0.0;
            
            

            for (int j = 0; j < n_total; j++) {
                int32_t dx = X_f[i] - X_f[j];
                int32_t dy = Y_f[i] - Y_f[j];
                double dx_float = X_float[i] - X_float[j];
                double dy_float = Y_float[i] - Y_float[j];

                // square distance
                int64_t D2_fixed = (int64_t)dx * dx + (int64_t)dy * dy;
                double D2_float = dx_float * dx_float + dy_float * dy_float;

                double D2_fixed_real = (D2_fixed / 65536.0) / (scale_points * scale_points);

                //printf("D2 float         = %f\n", D2_float);
                //printf("D2 fixed reconstr= %f\n", D2_fixed_real);
                //printf("rapport          = %f\n", D2_fixed_real / D2_float);

                int64_t mult = D2_fixed * -(K_fixed);

                int64_t arg_q16_16 = (mult >> 16);
                double arg_float = -D2_float / (2*T_float*T_float);
                
                double arg_fixed = arg_q16_16 / 65536.0;

                //printf("arg float         = %f\n", arg_float);
                //printf("arg fixed reconstr= %f\n", arg_fixed);
                //printf("rapport          = %f\n", arg_fixed / arg_float);

                if(arg_q16_16 > 0)
                {
                    printf("arg_q16_16 positif : %ld\n", arg_q16_16);
                    exit(1);
                }
                int64_t arg_q6_10;


                arg_q6_10 = arg_q16_16 >> 6;
                if(arg_q6_10 > 0)
                {
                    printf("arg_q6_10 positif : %ld\n", arg_q6_10);
                    exit(1);
                }
                
                
                if(arg_q6_10 < global_min_arg)
                    global_min_arg = arg_q6_10;

                if(arg_q6_10 > global_max_arg)
                    global_max_arg = arg_q6_10;
                

                if(arg_fixed > 0) count_positive++;
                if(arg_fixed > (-100) && arg_fixed < (-10)) count_arg_1++;
                if(arg_fixed > (-10) && arg_fixed < (-6)) count_arg_2++;
                if(arg_fixed > (-6) && arg_fixed < (-5)) count_arg_3++;
                if(arg_fixed > (-5) && arg_fixed < (-4))  count_arg_4++;
                if(arg_fixed > (-4) && arg_fixed < (-3))  count_arg_5++;
                if(arg_fixed > (-3)  && arg_fixed < (-2))  count_arg_6++;
                if(arg_fixed > (-2)  && arg_fixed < (-1))  count_arg_7++;
                if(arg_fixed > (-1)  && arg_fixed < 0 )  count_arg_8++;

                
                if(arg_q6_10 <= -(10 * 1024)){
                    P[i][j] = 0;
                }
                else {
                    int index = arg_q6_10 + 10240;
                    P[i][j] = exp_lut[index];
                }
                //if (count_pass_exp < 100) printf("LUT exp utilisé : P[i][j] = %d avec arg = %d -- i = %d & j = %d\n", P[i][j], arg_q6_10, i, j);
                count_pass_exp++;

                //if (i == 2 && step == 0) printf("i=%d  j=%d P_ij=%d\n", i, j, P[i][j]);

                //if (step == 0 && i == 0) fprintf(f_P_ij_fixed, "%d\n", P[i][j]);
            

                
                P_float[i][j] = exp(arg_float);
                
                
                if(P_float[i][j] > 0 && P[i][j] == 0)
                    lost++;


                sum_row_P += P[i][j];

                

                sum_row_P_float += P_float[i][j];
            }
            if (sum_row_P < sum_row_P_min) sum_row_P_min = sum_row_P;
            if (sum_row_P > sum_row_P_max) sum_row_P_max = sum_row_P;


            // Normalization matching MATLAB exactly: P = P ./ (sum(P, 2) + 1e-12)
            H[i] = 0.0;
            H_fixed[i] = 0.0;
            uint64_t gini_acc = 0;

            if (i <= 3 && step==0) printf("\nsum_row_P : %d\n\n", sum_row_P);
            for (int j = 0; j < n_total; j++) {

                uint16_t P_before = P[i][j];

                if(sum_row_P == 0)
                    P[i][j] = 0;
                else{
                    int msb = 31 - __builtin_clz(sum_row_P);
                    uint32_t mantissa = sum_row_P << (31 - msb);
                    uint32_t addr = (mantissa >> 22) & 0x3FF;

                    uint64_t mult = (uint64_t)P_before * inv[addr];

                    P[i][j] = mult >> msb;

                    //if (i <= 2 && step == 0) printf(" j=%d P_ij_norm=%d\n", j, P[i][j]);
                    
                    //ancienne version sanns LUT pour la division
                    //P[i][j] = ((uint32_t)P_before << 16) / sum_row_P;
                }
                
                P_float[i][j] /= (sum_row_P_float + 1e-12);
                
                double P_fixed = P[i][j] / 65536.0;


                double error = fabs(P_float[i][j]-P_fixed);

                if(error > 1e-6)
                {
                    //printf("i=%d j=%d\n", i,j);
                    //printf("P_float = %.10e\n", P_float[i][j]);
                    //printf("P_fixed = %.10e\n", P_fixed);
                    //printf("error   = %.10e\n", error);
                    //printf("ratio   = %.5f\n", P_float[i][j]/P_fixed);
                }

                if(error > max_error)
                    max_error = error;

                H[i] -= P_float[i][j] * log2(P_float[i][j] + 1e-12); // Cálculo da Entropia H

                uint16_t p = P[i][j];
                gini_acc += ((uint64_t)p*p)>>16;
            }
            H_fixed[i] = 65536 - gini_acc;
            //if (i < 2) printf("H_fixed%d : %d\n", i, H_fixed[i]);
            if (H_fixed[i] > max_H) max_H = H_fixed[i];
            if (H_fixed[i] < min_H) min_H = H_fixed[i];

            if (Y_f[i] > max_X_f) max_X_f = Y_f[i];
            if (Y_f[i] < min_X_f) min_X_f = Y_f[i];


            if (H_fixed[i] >= 62659 && H_fixed[i] < 63000)count_H_1++;
            if (H_fixed[i] >= 63000 && H_fixed[i] < 63500)count_H_2++;
            if (H_fixed[i] >= 63500 && H_fixed[i] < 64000)count_H_3++;
            if (H_fixed[i] >= 64000 && H_fixed[i] < 64500)count_H_4++;
            if (H_fixed[i] >= 64500 && H_fixed[i] < 65000)count_H_5++;
            if (H_fixed[i] >= 65000 && H_fixed[i] < 65250)count_H_6++;
            if (H_fixed[i] >= 65250 && H_fixed[i] < 65400)count_H_7++;
            if (H_fixed[i] >= 65400 && H_fixed[i] <= 65536)count_H_8++;

            if (H[i] <= 0.93) count_Hf_1++;
            if (H[i] > 0.93) count_Hf_2++;
        }

        // Passo B: Gradientes de Ricci e Atualização das Posições
        for (int i = 0; i < n_total; i++) {
            double P_dot_X_float = 0.0;
            double P_dot_Y_float = 0.0;
            int64_t P_dot_X = 0;
            int64_t P_dot_Y = 0;
            for (int j = 0; j < n_total; j++) {
                P_dot_X_float += P_float[i][j] * X_float[j];
                P_dot_Y_float += P_float[i][j] * Y_float[j];

                int64_t temp_X = P[i][j] * X_f[j];
                P_dot_X += temp_X;

                int64_t temp_Y = P[i][j] * Y_f[j];
                P_dot_Y += temp_Y;
            }
            P_dot_X = P_dot_X >> 16;
            P_dot_Y = P_dot_Y >> 16;

            if (i == 0 && step == 0) printf("P_dot_X : %d\n", P_dot_X);
            if (i == 0 && step == 0) printf("P_dot_Y : %d\n\n", P_dot_Y);
            if (i == 1 && step == 0) printf("P_dot_X : %d\n", P_dot_X);
            if (i == 1 && step == 0) printf("P_dot_Y : %d\n\n", P_dot_Y);
            if (i == 2 && step == 0) printf("P_dot_X : %d\n", P_dot_X);
            if (i == 2 && step == 0) printf("P_dot_Y : %d\n\n", P_dot_Y);

            double P_dot_X_real = (P_dot_X / 256.0) / scale_points + xmin;


            //printf("P_dot_X_float    = %f\n", P_dot_X_float);
            //printf("P_dot_X reconstr = %f\n", P_dot_X_real);
            //printf("rapport          = %f\n", P_dot_X_real / P_dot_X_float);

            grad_x_float[i] = P_dot_X_float - X_float[i];
            grad_y_float[i] = P_dot_Y_float - Y_float[i];
            grad_x[i] = P_dot_X - X_f[i];
            grad_y[i] = P_dot_Y - Y_f[i];

            if (i == 0 && step == 0) printf("grad_x : %d\n", grad_x[i]);
            if (i == 0 && step == 0) printf("grad_y : %d\n\n", grad_y[i]);
            if (i == 1 && step == 0) printf("grad_x : %d\n", grad_x[i]);
            if (i == 1 && step == 0) printf("grad_y : %d\n\n", grad_y[i]);
            if (i == 2 && step == 0) printf("grad_x : %d\n", grad_x[i]);
            if (i == 2 && step == 0) printf("grad_y : %d\n\n", grad_y[i]);
            
            double grad_x_real = (grad_x[i] / 256.0) / scale_points;

            //printf("grad_x_float    = %f\n", grad_x_float[i]);
            //printf("grad_x reconstr = %f\n", grad_x_real);
            //printf("rapport          = %f\n", grad_x_real / grad_x_float[i]);

            // Cirurgia de Perelman baseada no limiar de Entropia
            forca_float[i] = 0.35;
            forca[i] = (int32_t)(0.35 * 65536);
            if (H[i] > limiar_cirurgico) {
                forca_float[i] = 0.002;
            }
            if (H_fixed[i] > limiar_cirurgico_fixed) {
                forca[i] = (int32_t)(0.002 * 65536);
            }
        }

        // Atualização síncrona dos pontos para evitar distorções de iteração histórica
        for (int i = 0; i < n_total; i++) {
            X_float[i] += forca_float[i] * grad_x_float[i];
            Y_float[i] += forca_float[i] * grad_y_float[i];

            int64_t mult_act_X = ((int64_t)forca[i] * grad_x[i]) >> 16;
            int64_t mult_act_Y = ((int64_t)forca[i] * grad_y[i]) >> 16;
            if (mult_act_X > max_mult_act_X) max_mult_act_X = mult_act_X;
            if (mult_act_Y > max_mult_act_Y) max_mult_act_Y = mult_act_Y;
            if (mult_act_X < min_mult_act_X) min_mult_act_X = mult_act_X;
            if (mult_act_Y < min_mult_act_Y) min_mult_act_Y = mult_act_Y;

            //if (step == 0) fprintf(f_act, "%d %d\n", mult_act_X, mult_act_Y);


            //if (i <= 99 && step == 0) printf("mult_act_X : %d\n", mult_act_X);
            //if (i <= 99 && step == 0) printf("mult_act_Y : %d\n\n", mult_act_Y);
            X_f[i] += ((int64_t)forca[i] * grad_x[i]) >> 16;
            Y_f[i] += ((int64_t)forca[i] * grad_y[i]) >> 16;
            //if (i <= 99 && step == 49) printf("X_f_new : %d\n", X_f[i]);
            //if (i <= 99 && step == 49) printf("Y_f_w : %d\n\n", Y_f[i]);
        
            double X_f_real = (X_f[i] / 256.0) / scale_points + xmin;

            //printf("X_float    = %f\n", X_float[i]);
            //printf("X_f reconstr = %f\n", X_f_real);
            //printf("rapport          = %f\n", X_f_real / X_float[i]);
        }


        T_q8_8 = (uint32_t)(((uint64_t)T_q8_8 * alpha) >> 16);
        T_real = T_q8_8 / 256.0;
        T_float *= alpha_float;

        double T_fixed_float = T_q8_8 / (256.0 * scale_points);

        //printf("T float        = %.8f\n", T_float);
        //printf("T fixed recon  = %.8f\n", T_fixed_float);
        //printf("rapport        = %.8f\n", T_fixed_float / T_float);
    }

    //fclose(f_P_ij_fixed);
    fclose(f_hex);
    //fclose(f_act);
    printf("min_H : %d\n", min_H);
    printf("max_H : %d\n", max_H);
    printf("max_X_f : %d\n", max_X_f);
    printf("min_X_f : %d\n", min_X_f);
    printf("min_mult_act_X : %d\n", min_mult_act_X);
    printf("max_mult_act_X : %d\n", max_mult_act_X);
    printf("min_mult_act_Y : %d\n", min_mult_act_Y);
    printf("max_mult_act_Y : %d\n", max_mult_act_Y);
    printf("Distribution H_fixed:\n");
    printf("62659-63000 : %ld\n", count_H_1);
    printf("63000-63500 : %ld\n", count_H_2);
    printf("63500-64000 : %ld\n", count_H_3);
    printf("64000-64500 : %ld\n", count_H_4);
    printf("64500-65000 : %ld\n", count_H_5);
    printf("65000-65250 : %ld\n", count_H_6);
    printf("65250-65400 : %ld\n", count_H_7);
    printf("65400-65536 : %ld\n", count_H_8);
    printf("Distribution H_float Shannon:\n");
    printf("<= 0.93   : %ld\n", count_Hf_1);
    printf("> 0.93  : %ld\n", count_Hf_2);

    printf("sum_row_P_min : %lf\n", sum_row_P_min);
    printf("sum_row_P_max : %.2f\n", sum_row_P_max);

    printf("lost %.3f %%\n", (double)lost / (double)(n_total*n_total*max_iter) * 100.0);

    printf("exp argument range = [%f ; %f]\n",
       global_min_arg,
       global_max_arg);

    long total = 1250L * 1250L * max_iter;

    printf("nb_positif %ld\n", count_positive);
    printf("-100 < arg < -10 : %ld | proportion : %.2f %%\n",count_arg_1, (double)count_arg_1 / total * 100.0);
    printf("-10 < arg < -6 : %ld | proportion : %.2f %%\n",count_arg_2, (double)count_arg_2 / total * 100.0);
    printf("-6 < arg < -5 : %ld | proportion : %.2f %%\n",count_arg_3, (double)count_arg_3 / total * 100.0);
    printf("-5 < arg < -4 : %ld | proportion : %.2f %%\n",count_arg_4, (double)count_arg_4 / total * 100.0);
    printf("-4 < arg < -3 : %ld | proportion : %.2f %%\n",count_arg_5, (double)count_arg_5 / total * 100.0);
    printf("-3 < arg < -2 : %ld | proportion : %.2f %%\n",count_arg_6, (double)count_arg_6 / total * 100.0);
    printf("-2 < arg < -1 : %ld | proportion : %.2f %%\n",count_arg_7, (double)count_arg_7 / total * 100.0);
    printf("-1 < arg < 0 : %ld | proportion : %.2f %%\n",count_arg_8, (double)count_arg_8 / total * 100.0);



    clock_t end_time = clock();
    double t_calc = (double)(end_time - start_time) / CLOCKS_PER_SEC;

    // --- 3. AGRUPAMENTO GEOMÉTRICO FINAL ---
    int *cluster_labels = (int *)malloc(n_total * sizeof(int));
    for (int i = 0; i < n_total; i++) cluster_labels[i] = -1;
    int *cluster_labels_fixed = (int *)malloc(n_total * sizeof(int));
    for (int i = 0; i < n_total; i++) cluster_labels_fixed[i] = -1;

    int num_clusters_float = 0;
    int num_clusters_fixed = 0;
    // Tolerância adaptada para varrer o mapa físico preservando os lóbulos independentes
    double tol = 0.4 * 0.4;

    //uint32_t tol_fixed = (uint32_t)(tol * scale_points * scale_points * 65536.0);
    double scale_coord = (double)scale_points * 256.0;
    uint64_t tol_fixed = (uint64_t)(tol * scale_coord * scale_coord);
    printf("tol_fixed = %d\n", tol_fixed);

    for (int i = 0; i < n_total; i++) {
        if (cluster_labels[i] != -1) continue;

        cluster_labels[i] = num_clusters_float;

        for (int j = i + 1; j < n_total; j++) {
            if (cluster_labels[j] == -1) {
                double dx_float = X_float[i] - X_float[j];
                double dy_float = Y_float[i] - Y_float[j];
                double dist_float = dx_float * dx_float + dy_float * dy_float;

                if (dist_float <= tol) {
                    cluster_labels[j] = num_clusters_float;
                }
            }
        }
        num_clusters_float++;
    }

    for (int i = 0; i < n_total; i++) {
        if (cluster_labels_fixed[i] != -1) continue;

        cluster_labels_fixed[i] = num_clusters_fixed;

        for (int j = i + 1; j < n_total; j++) {
            if (cluster_labels_fixed[j] == -1) {
                int32_t dx = X_f[i] - X_f[j];
                int32_t dy = Y_f[i] - Y_f[j];


                int64_t dist_fixed = (int64_t)dx * dx + (int64_t)dy * dy;

                if (dist_fixed <= tol_fixed) {
                    cluster_labels_fixed[j] = num_clusters_fixed;
                }
            }
        }
        num_clusters_fixed++;
    }

    FILE *file_in = fopen(BENCHMARK_FILE, "r");
    FILE *file_out = fopen("../data/resultats_c.txt", "w");
    double val3_old;
    int i = 0;
    // Lecture ligne par ligne des 3 valeurs et remplacement de la 3ème
    while (fscanf(file_in, "%lf %lf %lf", &val1, &val2, &val3_old) == 3) {
        fprintf(file_out, "%.14f %.14f %d\n", val1, val2, cluster_labels_fixed[i]);
        i++;
    }

    fclose(file_in);
    fclose(file_out);

    
    for (int i = 0; i < n_total; i++) {
        //printf("cluster_fixed[%d] = %d || cluster_float[%d] = %d || X_f[%d] = %d Y_f[%d] = %d\n", i, cluster_labels_fixed[i], i, cluster_labels[i], i, X_f[i], i, Y_f[i]);
        //printf("cluster_fixed[%d] = %d\n", i, cluster_labels_fixed[i]);
    }



    int *cluster_sizes = (int *)calloc(num_clusters_float, sizeof(int));
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

    for (int c = 0; c < num_clusters_float; c++) {
        if (cluster_sizes[c] >= thresh) real_clusters_count++;
    }

    printf(">> TOTAL DE CLUSTERS DETECTADOS NA TEIA COSMOLÓGICA: %d <<\n", real_clusters_count);
    printf("------------------------------------------------------------------\n");
    printf("Métricas Finais de População de Nós:\n");

    int id_exibicao = 1;
    for (int c = 0; c < num_clusters_float; c++) {
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
    free(X); free(Y); free(X_f); free(Y_f); free(X_q); free(Y_q); 
    free(H); free(grad_x); free(grad_y); free(grad_x_float); free(grad_y_float); free(forca_float); free(forca);
    free(cluster_labels); free(cluster_labels_fixed); free(cluster_sizes); free(X_float); free(Y_float);
    for (int i = 0; i < n_total; i++) {
        free(P[i]);
        free(P_float[i]);
    }
    free(P_float);
    free(P);

    return 0;
}

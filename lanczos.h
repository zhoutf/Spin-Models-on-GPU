#include<iostream>
#include<cstdlib>
#include<cmath>
#include<fstream>
#include<iomanip>
#include"testhamiltonian.h"
#include"cuda.h"
#include"cuda_runtime.h"
#include"cublas_v2.h"
#include"cusparse_v2.h"
#include"cuComplex.h"

#define SIGN(a,b) ((b) >= 0.0 ? fabs(a) : -fabs(a))

using namespace std;

__host__ void lanczos(const int how_many, const int* num_Elem, d_hamiltonian*& Hamiltonian, int max_Iter, const int num_Eig, const double conv_req);

__global__ void normalize(cuDoubleComplex* v, const int size, double norm);

__host__ int tqli(vector<double> d, vector<double> e, int n, int max_Iter, double* z);

__host__ double pythag(double a, double b);

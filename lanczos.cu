// Katharine Hyatt
// A set of functions to implement the Lanczos method for a generic Hamiltonian
// Based on the codes Lanczos_07.cpp and Lanczos07.h by Roger Melko
//-------------------------------------------------------------------------------

#include"lanczos.h"

// h_ means this variable is going to be on the host (CPU)
// d_ means this variable is going to be on the device (GPU)
// s_ means this variable is shared between threads on the GPU
// The notation <<x,y>> before a function defined as global tells the GPU how many threads per block to use
// and how many blocks per grid to use
// blah.x means the real part of blah, if blah is a data type from cuComplex.h
// blah.y means the imaginary party of blah, if blah is a data type from cuComplex.h
// threadIdx.x (or block) means the "x"th thread from the left in the block (or grid)
// threadIdx.y (or block) means the "y"th thread from the top in the block (or grid)


__global__ void zero(cuDoubleComplex* a, int m){
  int i = blockDim.x*blockIdx.x + threadIdx.x;

  if ( i < m){
    a[i] = make_cuDoubleComplex(0., 0.) ;
  }
}


__global__ void zero(double* a, int m){
  int i = blockDim.x*blockIdx.x + threadIdx.x;

  if ( i < m ){
    a[i] = 0.;
  }
}

// Note: to get the identity matrix, apply the fuction zero above first
__global__ void unitdiag(double* a, int m){
  int i = blockDim.x*blockIdx.x + threadIdx.x;
  
  if (i < m ){

    a[i + m*i] = 1.;
  }
}


//Function lanczos: takes a hermitian matrix H, tridiagonalizes it, and finds the n smallest eigenvalues - this version only returns eigenvalues, not
// eigenvectors. Doesn't use sparse matrices yet either, derp. Should be a very simple change to make using CUSPARSE, which has functions for operations
// between sparse matrices and dense vectors
//---------------------------------------------------------------------------------------------------------------------------------------------------
// Input: h_H, a Hermitian matrix of complex numbers (not yet sparse)
//        dim, the dimension of the matrix
//        max_Iter, the starting number of iterations we'll try
//        num_Eig, the number of eigenvalues we're interested in seeing
//        conv_req, the convergence we'd like to see
//---------------------------------------------------------------------------------------------------------------------------------------------------
// Output: h_ordered, the array of the num_Eig smallest eigenvalues, ordered from smallest to largest
//---------------------------------------------------------------------------------------------------------------------------------------------------        

__host__ void lanczos(const int num_Elem, cuDoubleComplex*& d_H_vals, int*& d_H_rows, int*& d_H_cols, const int dim, int max_Iter, const int num_Eig, const double conv_req){

  cublasStatus_t linalgstat;
  //have to initialize the cuBLAS environment, or my program won't work! I could use this later to check for errors as well
  cublasHandle_t linalghandle;
  linalgstat = cublasCreate(&linalghandle);

  if (linalgstat != CUBLAS_STATUS_SUCCESS){
    std::cout<<"Initializing CUBLAS failed! Error: "<<linalgstat<<std::endl;
  }

  cusparseHandle_t sparsehandle;
  cusparseStatus_t sparsestatus = cusparseCreate(&sparsehandle); //have to initialize the cusparse environment too! This variable gets passed to all my cusparse functions

  if (sparsestatus != CUSPARSE_STATUS_SUCCESS){
    std::cout<<"Failed to initialize CUSPARSE! Error: "<<sparsestatus<<std::endl;
  }

  cusparseMatDescr_t H_descr = 0;
  sparsestatus = cusparseCreateMatDescr(&H_descr);
  if (sparsestatus != CUSPARSE_STATUS_SUCCESS){
    std::cout<<"Error creating matrix description: "<<sparsestatus<<std::endl;
  }
  sparsestatus = cusparseSetMatType(H_descr, CUSPARSE_MATRIX_TYPE_HERMITIAN);
  if (sparsestatus != CUSPARSE_STATUS_SUCCESS){
    std::cout<<"Error setting matrix type: "<<sparsestatus<<std::endl;
  }
  sparsestatus = cusparseSetMatIndexBase(H_descr, CUSPARSE_INDEX_BASE_ZERO);
  if (sparsestatus != CUSPARSE_STATUS_SUCCESS){
    std::cout<<"Error setting matrix index base: "<<sparsestatus<<std::endl;
  }

  cudaError_t status1, status2, status3, status4;

  int* d_H_rowptrs;
  status1 = cudaMalloc(&d_H_rowptrs, (dim + 1)*sizeof(int));
  if (status1 != CUDA_SUCCESS){ 
    std::cout<<"Error allocating d_H_rowptrs: "<<cudaGetErrorString(status1)<<std::endl;
  }

  sparsestatus = cusparseXcoo2csr(sparsehandle, d_H_rows, num_Elem, dim, d_H_rowptrs, CUSPARSE_INDEX_BASE_ZERO);

  if (sparsestatus != CUSPARSE_STATUS_SUCCESS){
    std::cout<<"Failed to switch from COO to CSR! Error: "<<sparsestatus<<std::endl;
  }
  cudaThreadSynchronize();
  std::cout<<"Going from COO to CSR complete"<<std::endl;

  size_t heap;
  cudaDeviceGetLimit(&heap, cudaLimitMallocHeapSize);
  std::cout<<"GPU heap size: "<<heap<<std::endl;
  
  thrust::device_vector<cuDoubleComplex> d_a;
  try {
    d_a.resize(max_Iter);
  }

  catch( thrust::system_error e) {
    std::cerr << "Error creating d_a: "<< e.what() <<std::endl;
    exit(-1);
  }

  catch( std::bad_alloc &e){
    std::cerr<<"Couldn't allocate d_a"<<std::endl;
    exit(-1);
  }
  std::cout<<"Creating d_a complete"<<std::endl;
  
  thrust::device_vector<cuDoubleComplex> d_b;
  try {
    d_b.resize(max_Iter);
  }

  catch( thrust::system_error e) {
    std::cerr << "Error creating d_b: "<< e.what() <<std::endl;
    exit(-1);
  }
  catch( std::bad_alloc ){
    std::cerr<<"Couldn't allocated d_b"<<std::endl;
    exit(-1);
  }

  cuDoubleComplex* d_a_ptr;
  cuDoubleComplex* d_b_ptr; //we need these to pass to kernel functions 
  std::cout<<"Creating d_b complete"<<std::endl;
  
  int tpb = 256; //threads per block - a conventional number
  int bpg = (dim + tpb - 1)/tpb; //blocks per grid

  //Making the "random" starting vector

  thrust::device_vector<cuDoubleComplex> d_lanczvec; //this thing is an array of the Lanczos vectors 
  try{
    d_lanczvec.resize(dim*max_Iter);
  }
  catch( thrust::system_error e){
    std::cerr<<"Error creating d_lanczvec: "<<e.what()<<std::endl;
    exit(-1);
  }

  cuDoubleComplex* lancz_ptr = thrust::raw_pointer_cast(&d_lanczvec[0]);
 
  std::cout<<"Creating d_lanczvec complete"<<std::endl;

  cuDoubleComplex* v0;
  cuDoubleComplex* v1;
  cuDoubleComplex* v2;
  status1 = cudaMalloc(&v0, dim*sizeof(cuDoubleComplex));
  status2 = cudaMalloc(&v1, dim*sizeof(cuDoubleComplex));
  status3 = cudaMalloc(&v2, dim*sizeof(cuDoubleComplex));

  thrust::device_ptr<cuDoubleComplex> v0_ptr(v0);
  thrust::device_ptr<cuDoubleComplex> v1_ptr(v1);
  thrust::device_ptr<cuDoubleComplex> v2_ptr(v2);

  //thrust::device_vector<cuDoubleComplex> v0(dim);
  //thrust::device_vector<cuDoubleComplex> v1(dim);
  //thrust::device_vector<cuDoubleComplex> v2(dim);
  //cuDoubleComplex* v0_ptr = thrust::raw_pointer_cast(&v0[0]);
  //cuDoubleComplex* v1_ptr = thrust::raw_pointer_cast(&v1[0]);
  //cuDoubleComplex* v2_ptr = thrust::raw_pointer_cast(&v2[0]);
  std::cout<<"Creating the three lanczos vectors complete"<<std::endl;

  cuDoubleComplex* host_v0 = (cuDoubleComplex*)malloc(dim*sizeof(cuDoubleComplex));
  for(int i = 0; i<dim; i++){
    host_v0[i] = make_cuDoubleComplex(1., 0.);
  }

  cudaMemcpy(v0, host_v0, dim*sizeof(cuDoubleComplex), cudaMemcpyHostToDevice);

  //thrust::fill(v0.begin(), v0.end(), make_cuDoubleComplex(1., 0.));//assigning the values of the "random" starting vector
  std::cout<<"Filling the starting vector complete"<<std::endl;

  cuDoubleComplex alpha = make_cuDoubleComplex(1.,0.);
  cuDoubleComplex beta = make_cuDoubleComplex(0.,0.); 

  cudaThreadSynchronize();

  sparsestatus = cusparseZcsrmv(sparsehandle, CUSPARSE_OPERATION_NON_TRANSPOSE, dim, dim, alpha, H_descr, d_H_vals, d_H_rowptrs, d_H_cols, v0, beta, v1); // the Hamiltonian is applied here

  if (sparsestatus != CUSPARSE_STATUS_SUCCESS){
    std::cout<<"Getting V1 = H*V0 failed! Error: ";
    std::cout<<sparsestatus<<std::endl;
  }
  cudaThreadSynchronize();
  std::cout<<"Getting V1 = H*V0 complete"<<std::endl;
  if (sparsestatus != CUSPARSE_STATUS_SUCCESS){
    std::cout<<"Getting V1 = H*V0 failed! Error: ";
    std::cout<<sparsestatus<<std::endl;
  }
  if (cudaPeekAtLastError() != 0 ){
    std::cout<<"Getting V1  = H*V0 failed! Error: ";
    std::cout<<cudaGetErrorString(cudaPeekAtLastError())<<std::endl;
  } 
  //*********************************************************************************************************
  
  // This is just the first steps so I can do the rest
  
  try{ 
    d_a_ptr = raw_pointer_cast(&d_a[0]);  
  }
  catch( thrust::system_error e ){
    std::cerr<<"Error settng d_a_ptr: "<<e.what()<<std::endl;
    exit(-1);
  }
  std::cout<<"Setting d_a_ptr complete"<<std::endl;

  std::cout<<d_a_ptr<<std::endl;
  cuDoubleComplex dottemp;
   
  linalgstat = cublasZdotc(linalghandle, dim, v1, 1, v0, 1, &dottemp); 
  if (linalgstat != CUBLAS_STATUS_SUCCESS){
    std::cout<<"Getting d_a[0] failed! Error: ";
    std::cout<<linalgstat<<std::endl;
  }
  cudaMemcpy(d_a_ptr, &dottemp, sizeof(cuDoubleComplex), cudaMemcpyHostToDevice);
  //d_b[0] = make_cuDoubleComplex(0.,0.);
  std::cout<<"Getting d_a[0] started"<<std::endl;
  cudaThreadSynchronize();
  if (linalgstat != CUBLAS_STATUS_SUCCESS){
    std::cout<<"Getting d_a[0] failed! Error: ";
    std::cout<<linalgstat<<std::endl;
  }
  std::cout<<"Getting d_a[0] complete"<<std::endl;

  d_b[0] = make_cuDoubleComplex(0., 0.);

  cuDoubleComplex* y;
  status2 = cudaMalloc(&y, dim*sizeof(cuDoubleComplex));

  if (status2 != CUDA_SUCCESS){
          std::cout<<"Memory allocation of y dummy vector failed! Error:";
          std::cout<<cudaGetErrorString( status2 )<<std::endl;
  }
  
  zero<<<dim/512 + 1, 512>>>(y, dim);
  cudaThreadSynchronize();
  std::cout<<"Zeroing y complete"<<std::endl;

  double* double_temp;
  status4 = cudaMalloc(&double_temp, sizeof(double));
  if (status4 != CUDA_SUCCESS){
    std::cout<<"Error allocating double_temp! Error: ";
    std::cout<<cudaGetErrorString(status4)<<std::endl;
  }

  thrust::device_ptr<double> double_temp_ptr(double_temp);

  cuDoubleComplex* cuDouble_temp;
  status1 = cudaMalloc(&cuDouble_temp, sizeof(cuDoubleComplex));
  if (status1 != CUDA_SUCCESS){
    std::cout<<"Error allocating cuDouble_temp! Error: ";
    std::cout<<cudaGetErrorString(status4)<<std::endl;
  }

  thrust::device_ptr<cuDoubleComplex> cuDouble_temp_ptr(cuDouble_temp);


  *cuDouble_temp_ptr = cuCmul(make_cuDoubleComplex(-1., 0), d_a[0]);
  std::cout<<"Getting V1 - alpha*V0 started"<<std::endl;
  
  cuDoubleComplex axpytemp = cuCmul(make_cuDoubleComplex(-1.,0), d_a[0]);
  linalgstat = cublasZaxpy(linalghandle, dim, &axpytemp, v0, 1, v1, 1);
  
  if (linalgstat != CUBLAS_STATUS_SUCCESS){
    std::cout<<"V1 = V1 - alpha*V0 failed! Error: ";
    std::cout<<linalgstat<<std::endl;
  }
  cudaThreadSynchronize();
  std::cout<<"V1 = V1 - alpha*V0 complete"<<std::endl;

 
  d_b_ptr = thrust::raw_pointer_cast(&d_b[1]);
  double normtemp;
  linalgstat = cublasDznrm2(linalghandle, dim, v1, 1, &normtemp);
  
  if (linalgstat != CUBLAS_STATUS_SUCCESS){
    std::cout<<"Getting the norm of v1 failed! Error: ";
    std::cout<<linalgstat<<std::endl;
  }
  
  d_b[1] = make_cuDoubleComplex(sqrt(normtemp),0.);
  // this function (above) takes the norm
  
  cuDoubleComplex gamma = make_cuDoubleComplex(1./cuCreal(d_b[1]),0.); //alpha = 1/beta in v1 = v1 - alpha*v0

  linalgstat = cublasZaxpy(linalghandle, dim, &gamma, v1, 1, y, 1); // function performs a*x + y

  if (linalgstat != CUBLAS_STATUS_SUCCESS){
    std::cout<<"Getting 1/gamma * v1 failed! Error: ";
    std::cout<<linalgstat<<std::endl;
  }

  //Now we're done the first round!
  //*********************************************************************************************************

  thrust::device_vector<double> d_ordered(num_Eig);
  thrust::fill(d_ordered.begin(), d_ordered.end(), 0);
  double* d_ordered_ptr = thrust::raw_pointer_cast(&d_ordered[0]); 

  double gs_Energy = 1.; //the lowest energy

  int returned;

  int iter = 0;

  // In the original code, we started diagonalizing from iter = 5 and above. I start from iter = 1 to minimize issues of control flow
  thrust::device_vector<double> d_diag(max_Iter);
  double* diag_ptr;
  thrust::device_vector<double> d_offdia(max_Iter);
  double* offdia_ptr;
  thrust::host_vector<double> h_diag(max_Iter);
  double* h_diag_ptr = raw_pointer_cast(&h_diag[0]);
  thrust::host_vector<double> h_offdia(max_Iter);
  double* h_offdia_ptr = raw_pointer_cast(&h_offdia[0]);


  thrust::device_vector<cuDoubleComplex> temp(dim);
  cuDoubleComplex* temp_ptr = thrust::raw_pointer_cast(&temp[0]);

  double eigtemp = 0.;

  while( fabs(gs_Energy - eigtemp)> conv_req){ //this is a cleaner version than what was in the original - way fewer if statements

    iter++;

    status1 = cudaMemcpy(&eigtemp, d_ordered_ptr, sizeof(double), cudaMemcpyDeviceToHost);

    if (status1 != CUDA_SUCCESS){
      printf("Copying last eigenvalue failed \n");
    }
    std::cout<<"Getting V2 = H*V1 for the "<<iter + 1<<"th time"<<std::endl;
    sparsestatus = cusparseZcsrmv(sparsehandle, CUSPARSE_OPERATION_NON_TRANSPOSE, dim, dim, alpha, H_descr, d_H_vals, d_H_rowptrs, d_H_cols, v1, beta, v2); // the Hamiltonian is applied here, in this gross expression
    cudaThreadSynchronize();
    if (sparsestatus != CUSPARSE_STATUS_SUCCESS){
      std::cout<<"Error applying the Hamiltonian in "<<iter<<"th iteration!";
      std::cout<<"Error: "<<sparsestatus<<std::endl;
    } 

    d_a_ptr = thrust::raw_pointer_cast(&d_a[iter]);
    std::cout<<"Getting V1*V2 for the "<<iter + 1<<"th time"<<std::endl;
    linalgstat = cublasZdotc(linalghandle, dim, v1, 1, v2, 1, &dottemp);
    cudaThreadSynchronize();
    d_a[iter] = dottemp;

    if (linalgstat != CUBLAS_STATUS_SUCCESS){
      std::cout<<"Error getting v1 * v2 in "<<iter<<"th iteration! Error: ";
      std::cout<<linalgstat<<std::endl;
    }

    cudaMemcpy(temp_ptr, v1, dim*sizeof(cuDoubleComplex), cudaMemcpyDeviceToDevice);
    //temp = v1;

    axpytemp = cuCdiv(d_b[iter], d_a[iter]);
    *cuDouble_temp_ptr = cuCdiv(d_b[iter], d_a[iter]);

    linalgstat = cublasZaxpy( linalghandle, dim, &axpytemp, v0, 1, temp_ptr, 1);
    if (linalgstat != CUBLAS_STATUS_SUCCESS){
      std::cout<<"Error getting (d_b/d_a)*v0 + v1 in "<<iter<<"th iteration!";
      std::cout<<"Error: "<<linalgstat<<std::endl;
    }
    cudaThreadSynchronize();
    axpytemp = d_a[iter];
    linalgstat = cublasZaxpy( linalghandle, dim, &axpytemp, temp_ptr, 1, v2, 1);
    if (linalgstat != CUBLAS_STATUS_SUCCESS){
      std::cout<<"Error getting v2 + d_a*v1 in "<<iter<<"th iteration! Error: ";
      std::cout<<linalgstat<<std::endl;
    }
    std::cout<<"Getting norm of V2 for the "<<iter + 1<<"th time"<<std::endl;
    linalgstat = cublasDznrm2( linalghandle, dim, v2, 1, &normtemp);
    if (linalgstat != CUBLAS_STATUS_SUCCESS){
      std::cout<<"Error getting norm of v2 in "<<iter<<"th iteration! Error: ";
      std::cout<<linalgstat<<std::endl;
    }

    d_b[iter + 1] = make_cuDoubleComplex(sqrt(normtemp), 0.);
    
    gamma = make_cuDoubleComplex(1./cuCreal(d_b[iter+1]),0.);
    linalgstat = cublasZaxpy(linalghandle, dim, &gamma, v2, 1, y, 1);
    if (linalgstat != CUBLAS_STATUS_SUCCESS){ 
      std::cout<<"Error getting 1/d_b * v2 in "<<iter<<"th iteration! Error: ";
      std::cout<<linalgstat<<std::endl;
    }

    lancz_ptr = raw_pointer_cast(&d_lanczvec[dim*(iter - 1)]);
    std::cout<<"Copying the lanczos vectors"<<std::endl;
    cudaMemcpy(lancz_ptr, v0, dim*sizeof(cuDoubleComplex), cudaMemcpyDeviceToDevice);
    cudaMemcpy(v0, v1, dim*sizeof(cuDoubleComplex), cudaMemcpyDeviceToDevice);
    cudaMemcpy(v1, v2, dim*sizeof(cuDoubleComplex), cudaMemcpyDeviceToDevice);
    
    //thrust::copy(v0.begin(), v0.end(), &d_lanczvec[dim*(iter - 1)]);
    //thrust::copy(v1.begin(), v1.end(), v0.begin());
    //thrust::copy(v2.begin(), v2.end(), v1.begin()); //moving things around

    d_diag[iter] = cuCreal(d_a[iter]); //adding another spot in the tridiagonal matrix representation
    d_offdia[iter + 1] = cuCreal(d_b[iter + 1]);

  //this tqli stuff is a bunch of crap and needs to be fixed  
    double* d_H_eigen;
    size_t d_eig_pitch;

    status1 = cudaMalloc(&d_H_eigen, max_Iter*max_Iter*sizeof(double));
    if (status1 != CUDA_SUCCESS){
      printf("tqli eigenvectors matrix memory allocation failed! \n");
    }
    
    zero<<<bpg,tpb>>>(d_H_eigen, iter);
    unitdiag<<<bpg,tpb>>>(d_H_eigen, iter); //set this matrix to the identity
    h_diag = d_diag;
    h_offdia = d_offdia;

    double* h_H_eigen = (double*)malloc(max_Iter*max_Iter*sizeof(double));
    cudaMemcpy(h_H_eigen, d_H_eigen, max_Iter*max_Iter*sizeof(double), cudaMemcpyDeviceToHost);
    returned = tqli(h_diag_ptr, h_offdia_ptr, iter + 1, h_H_eigen); //tqli is in a separate file   
//

    d_diag = h_diag;
    thrust::sort(d_diag.begin(), d_diag.end());
    thrust::copy(d_diag.begin(), d_diag.begin() + num_Eig, d_ordered.begin());
   
    d_ordered_ptr = thrust::raw_pointer_cast(&d_ordered[num_Eig - 1]);
    status2 = cudaMemcpy(&gs_Energy, d_ordered_ptr, sizeof(double), cudaMemcpyDeviceToHost);

    if (status2 != CUDA_SUCCESS){
      printf("Copying the eigenvalue failed! \n");
    }

    if (iter == max_Iter - 1){// have to use this or d_b will overflow
      //this stuff here is used to resize the main arrays in the case that we aren't converging quickly enough
      d_a.resize(2*max_Iter);
      d_b.resize(2*max_Iter);
      d_diag.resize(2*max_Iter);
      d_offdia.resize(2*max_Iter);
      h_diag.resize(2*max_Iter);
      h_offdia.resize(2*max_Iter);
      d_lanczvec.resize(2*max_Iter*dim);
      max_Iter *= 2;
    }
    cudaFree(d_H_eigen);
       
  } 

  thrust::host_vector<double> h_ordered(num_Eig);
  h_ordered = d_ordered;

  for(int i = 0; i < num_Eig; i++){
    std::cout<<h_ordered[i]<<" ";
  } //write out the eigenenergies
  std::cout<<std::endl;
  cudaFree(double_temp);
  cudaFree(cuDouble_temp);
  // call the expectation values function
  
  // time to copy back all the eigenvectors
  thrust::host_vector<cuDoubleComplex> h_lanczvec(max_Iter*dim);
  h_lanczvec = d_lanczvec;
  
  // now the eigenvectors are available on the host CPU

  linalgstat = cublasDestroy(linalghandle);
	
  if (linalgstat != CUBLAS_STATUS_SUCCESS){
    printf("CUBLAS failed to shut down properly! \n");
  }

  sparsestatus = cusparseDestroy(sparsehandle);

  if (sparsestatus != CUSPARSE_STATUS_SUCCESS){
    printf("CUSPARSE failed to release handle! \n");
  }
  cudaFree(v0);
  cudaFree(v1);
  cudaFree(v2);
}
// things left to do:
// write a thing (separate file) to call routines to find expectation values, should be faster on GPU 
// make the tqli thing better!

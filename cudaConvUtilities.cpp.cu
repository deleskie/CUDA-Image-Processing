using namespace std;

#include <stdio.h>
#include <vector>
#include <iostream>
#include <fstream>
#include "cudaConvUtilities.h.cu"
using namespace std;

unsigned int cpuTimerVariable;
cudaEvent_t eventTimerStart;
cudaEvent_t eventTimerStop;

// Assume target memory has already been allocated, nPixels is odd
void createGaussian1D(float* targPtr, 
                      int    nPixels, 
                      float  sigma, 
                      float  ctr)
{
   if(nPixels%2 != 1)
   {
      cout << "***Warning: createGaussian(...) only defined for odd pixel"  << endl;
      cout << "            dimensions.  Undefined behavior for even sizes." << endl;
   }

   float pxCtr = (float)(nPixels/2 + ctr);   
   float sigmaSq = sigma*sigma;
   float denom = sqrt(2*M_PI*sigmaSq);
   float dist;
   for(int i=0; i<nPixels; i++)
   {
      dist = (float)i - pxCtr;
      targPtr[i] = exp(-0.5 * dist * dist / sigmaSq) / denom;
   }
}

// Assume target memory has already been allocate, nPixels is odd
// Use col-row (D00_UL_ES)
void createGaussian2D(float* targPtr, 
                      int    nPixelsCol,
                      int    nPixelsRow,
                      float  sigmaCol,
                      float  sigmaRow,
                      float  ctrCol,
                      float  ctrRow)
{
   if(nPixelsCol%2 != 1 || nPixelsRow != 1)
   {
      cout << "***Warning: createGaussian(...) only defined for odd pixel"  << endl;
      cout << "            dimensions.  Undefined behavior for even sizes." << endl;
   }

   float pxCtrCol = (float)(nPixelsCol/2 + ctrCol);   
   float pxCtrRow = (float)(nPixelsRow/2 + ctrRow);   
   float distCol, distRow, distColSqNorm, distRowSqNorm;
   float denom = 2*M_PI*sigmaCol*sigmaRow;
   for(int c=0; c<nPixelsCol; c++)
   {
      distCol = (float)c - pxCtrCol;
      distColSqNorm = distCol*distCol / (sigmaCol*sigmaCol);
      for(int r=0; r<nPixelsRow; r++)
      {
         distRow = (float)r - pxCtrRow;
         distRowSqNorm = distRow*distRow / (sigmaRow*sigmaRow);
         
         targPtr[c*nPixelsRow+r] = exp(-0.5*(distColSqNorm + distRowSqNorm)) / denom;
      }
   }
}


// Assume diameter^2 target memory has already been allocated
// This filter is used for edge detection.  Convolve with the
// kernel created by this function, and then look for the 
// zero-crossings
// As always, we expect an odd diameter
// For LoG kernels, we always assume square and symmetric,
// which is why there are no options for different dimensions
void createLaplacianOfGaussianKernel(float* targPtr,
                                     int    diameter)
{
   float pxCtr = (float)(diameter-1) / 2.0f;
   float dc, dr, dcSq, drSq;
   float sigma = diameter/10.0f;
   float sigmaSq = sigma*sigma;
   for(int c=0; c<diameter; c++)
   {
      dc = (float)c - pxCtr;
      dcSq = dc*dc;
      for(int r=0; r<diameter; r++)
      {
         dr = (float)r - pxCtr;
         drSq = dr*dr;
   
         float firstTerm  = (dcSq + drSq - 2*sigmaSq) / (sigmaSq * sigmaSq);
         float secondTerm = exp(-0.5 * (dcSq + drSq) / sigmaSq);
         targPtr[c*diameter+r] = firstTerm * secondTerm;
      }
   }
}

// Assume diameter^2 target memory has already been allocated
int createBinaryCircle(float* targPtr,
                       int    diameter)
{
   float pxCtr = (float)(diameter-1) / 2.0f;
   float rad;
   int seNonZero = 0;
   for(int c=0; c<diameter; c++)
   {
      for(int r=0; r<diameter; r++)
      {
         rad = sqrt((c-pxCtr)*(c-pxCtr) + (r-pxCtr)*(r-pxCtr));
         if(rad <= pxCtr+0.5)
         {
            targPtr[c*diameter+r] = 1.0f;
            seNonZero++;
         }
         else
         {
            targPtr[c*diameter+r] = 0.0f;
         }
      }
   }
   return seNonZero;
}

// Assume diameter^2 target memory has already been allocated
int createBinaryCircle(int*   targPtr,
                       int    diameter)
{
   float pxCtr = (float)(diameter-1) / 2.0f;
   float rad;
   int seNonZero = 0;
   for(int c=0; c<diameter; c++)
   {
      for(int r=0; r<diameter; r++)
      {
         rad = sqrt((c-pxCtr)*(c-pxCtr) + (r-pxCtr)*(r-pxCtr));
         if(rad <= pxCtr+0.5)
         {
            targPtr[c*diameter+r] = 1.0f;
            seNonZero++;
         }
         else
         {
            targPtr[c*diameter+r] = 0.0f;
         }
      }
   }
   return seNonZero;
}

////////////////////////////////////////////////////////////////////////////////
// Simple Timing Calls
void cpuStartTimer(void)
{
   // GPU Timer Functions
   cpuTimerVariable = 0;
   cutCreateTimer( &cpuTimerVariable );
   cutStartTimer(   cpuTimerVariable );
}

////////////////////////////////////////////////////////////////////////////////
// Stopping also resets the timer
// returns milliseconds
float cpuStopTimer(void)
{
   cutStopTimer( cpuTimerVariable );
   float cpuTime = cutGetTimerValue(cpuTimerVariable);
   cutDeleteTimer( cpuTimerVariable );
   return cpuTime;
}

////////////////////////////////////////////////////////////////////////////////
// Timing Calls for GPU -- this only counts GPU clock cycles, which will be 
// more precise for measuring GFLOPS and xfer rates, but shorter than wall time
void gpuStartTimer(void)
{
   cudaEventCreate(&eventTimerStart);
   cudaEventCreate(&eventTimerStop);
   cudaEventRecord(eventTimerStart);
}

////////////////////////////////////////////////////////////////////////////////
// Stopping also resets the timer
float gpuStopTimer(void)
{
   cudaEventRecord(eventTimerStop);
   cudaEventSynchronize(eventTimerStop);
   float gpuTime;
   cudaEventElapsedTime(&gpuTime, eventTimerStart, eventTimerStop);
   return gpuTime;
}

////////////////////////////////////////////////////////////////////////////////
// Read/Write images from/to files
void ReadFile(string fn, int* targPtr, int nCols, int nRows)
{
   ifstream in(fn.c_str(), ios::in);
   // We work with col-row format, but files written in row-col, so switch loop
   for(int r=0; r<nRows; r++)
      for(int c=0; c<nCols; c++)
         in >> targPtr[c*nCols+r];
   in.close();
}

////////////////////////////////////////////////////////////////////////////////
// Writing file in space-separated format
void WriteFile(string fn, int* srcPtr, int nCols, int nRows)
{
   ofstream out(fn.c_str(), ios::out);
   // We work with col-row format, but files written in row-col, so switch loop
   for(int r=0; r<nRows; r++)
   {
      for(int c=0; c<nCols; c++)
      {
         out << srcPtr[c*nRows+r] << " ";
      }
      out << endl;
   }
   out.close();
}

////////////////////////////////////////////////////////////////////////////////
// Writing image to stdout
void PrintArray(int* srcPtr, int nCols, int nRows)
{
   // We work with col-row format, but files written in row-col, so switch loop
   for(int r=0; r<nRows; r++)
   {
      cout << "\t";
      for(int c=0; c<nCols; c++)
      {
         cout << srcPtr[c*nRows+r] << " ";
      }
      cout << endl;
   }
}




////////////////////////////////////////////////////////////////////////////////
// Copy a 3D texture from a host (float*) array to a device cudaArray
// The extent should be specified with all dimensions in units of *elements*
void prepareCudaTexture(float* h_src, 
                        cudaArray *d_dst,
                        cudaExtent const texExtent)
{
   cudaMemcpy3DParms copyParams = {0};
   cudaPitchedPtr cppImgPsf = make_cudaPitchedPtr( (void*)h_src, 
                                                   texExtent.width*FLOAT_SZ,
                                                   texExtent.width,  
                                                   texExtent.height);
   copyParams.srcPtr   = cppImgPsf;
   copyParams.dstArray = d_dst;
   copyParams.extent   = texExtent;
   copyParams.kind     = cudaMemcpyHostToDevice;
   cutilSafeCall( cudaMemcpy3D(&copyParams) );
}
////////////////////////////////////////////////////////////////////////////////


////////////////////////////////////////////////////////////////////////////////
// BASIC UNARY & BINARY *MASK* OPERATORS
// 
// Could create LUTs, but I'm not sure the extra implementation complexity
// actually provides much benefit.  These ops already run on the order of
// microseconds.
//
// NOTE:  These operators are for images with {0,1}, only the MORPHOLOGICAL
//        operators will operate with {-1,0,1}
//
////////////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////////////
__global__ void  Mask_Union_Kernel( int* A, int* B, int* devOut)
{  
   const int idx = blockDim.x*blockIdx.x + threadIdx.x;

   if( A[idx] + B[idx] > 0)
      devOut[idx] = 1;
   else
      devOut[idx] = 0;
}

////////////////////////////////////////////////////////////////////////////////
__global__ void  Mask_Intersect_Kernel( int* A, int* B, int* devOut)
{  
   const int idx = blockDim.x*blockIdx.x + threadIdx.x;
   devOut[idx] = A[idx] * B[idx];
}

////////////////////////////////////////////////////////////////////////////////
// (A - B):   A is set to 0 if B is 1, otherwise A is left alone
__global__ void  Mask_Subtract_Kernel( int* A, int* B, int* devOut)
{  
   const int idx = blockDim.x*blockIdx.x + threadIdx.x;
   if( B[idx] == 0)
      devOut[idx] = 0;
   else 
      devOut[idx] = A[idx];
}

////////////////////////////////////////////////////////////////////////////////
__global__ void  Mask_Invert_Kernel( int* A, int* devOut)
{  
   const int idx = blockDim.x*blockIdx.x + threadIdx.x;
   devOut[idx] = 1 - A[idx];
}


////////////////////////////////////////////////////////////////////////////////
// TODO: This is a very dumb/slow equal operator, actually won't even work
//       Perhaps have the threads atomicAdd to a globalMem location if !=
//__global__ void  Mask_CountDiff_Kernel( int* A, int* B, int* globalMemCount)
//{  
   //const int idx = blockDim.x*blockIdx.x + threadIdx.x;
   //if(A[idx] != B[idx])
      //atomicAdd(numNotEqual, 1);
//}


////////////////////////////////////////////////////////////////////////////////
// TODO: Need to use reduction for this, but that can be kind of complicated
//__global__ void  Mask_Sum_Kernel( int* A, int* globalMemSum)
//{  
   //const int idx = blockDim.x*blockIdx.x + threadIdx.x;
   //if(A[idx] != B[idx])
      //atomicAdd(numNotEqual, 1);
//}

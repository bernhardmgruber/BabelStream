// Copyright (c) 2020 Tom Deakin, 2024 Bernhard Manfred Gruber
// University of Bristol HPC, NVIDIA
//
// For full license terms please see the LICENSE file distributed with this
// source code

#include "ThrustStream.h"
#include <thrust/inner_product.h>
#include <thrust/device_vector.h>
#include <thrust/iterator/zip_iterator.h>
#include <thrust/zip_function.h>

#if defined(MANAGED)
#include <thrust/universal_vector.h>
#else
#include <thrust/device_vector.h>
#endif

template <class T>
using vector =
#if defined(MANAGED)
  thrust::universal_vector<T>;
#else
  thrust::device_vector<T>;
#endif

template <class T>
struct ThrustStream<T>::Impl{
  vector<T> a, b, c;
};

static inline void synchronise()
{
// rocThrust doesn't synchronise between thrust calls
#if defined(THRUST_DEVICE_SYSTEM_HIP) && THRUST_DEVICE_SYSTEM == THRUST_DEVICE_SYSTEM_HIP
  hipDeviceSynchronize();
#endif
}

template <class T>
ThrustStream<T>::ThrustStream(const intptr_t array_size, int device)
    : array_size{array_size}, impl(new Impl{vector<T>(array_size), vector<T>(array_size), vector<T>(array_size)}) {
  std::cout << "Using CUDA device: " << getDeviceName(device) << std::endl;
  std::cout << "Driver: " << getDeviceDriver(device) << std::endl;
  std::cout << "Thrust version: " << THRUST_VERSION << std::endl;

#if THRUST_DEVICE_SYSTEM == 0
  // as per Thrust docs, 0 is reserved for undefined backend
  std::cout << "Thrust backend: undefined" << std::endl;
#elif THRUST_DEVICE_SYSTEM == THRUST_DEVICE_SYSTEM_CUDA
  std::cout << "Thrust backend: CUDA" << std::endl;
#elif THRUST_DEVICE_SYSTEM == THRUST_DEVICE_SYSTEM_OMP
  std::cout << "Thrust backend: OMP" << std::endl;
#elif THRUST_DEVICE_SYSTEM == THRUST_DEVICE_SYSTEM_TBB
  std::cout << "Thrust backend: TBB" << std::endl;
#elif THRUST_DEVICE_SYSTEM == THRUST_DEVICE_SYSTEM_CPP
  std::cout << "Thrust backend: CPP" << std::endl;
#elif THRUST_DEVICE_SYSTEM == THRUST_DEVICE_SYSTEM_TBB
  std::cout << "Thrust backend: TBB" << std::endl;
#else

#if defined(THRUST_DEVICE_SYSTEM_HIP) && THRUST_DEVICE_SYSTEM == THRUST_DEVICE_SYSTEM_HIP
  std::cout << "Thrust backend: HIP" << std::endl;
#else
  std::cout << "Thrust backend: " << THRUST_DEVICE_SYSTEM << "(unknown)" << std::endl;
#endif

#endif

}

template <class T>
ThrustStream<T>::~ThrustStream() = default;

template <class T>
void ThrustStream<T>::init_arrays(T initA, T initB, T initC)
{
  thrust::fill(impl->a.begin(), impl->a.end(), initA);
  thrust::fill(impl->b.begin(), impl->b.end(), initB);
  thrust::fill(impl->c.begin(), impl->c.end(), initC);
  synchronise();
}

template <class T>
void ThrustStream<T>::read_arrays(std::vector<T>& h_a, std::vector<T>& h_b, std::vector<T>& h_c)
{
  thrust::copy(impl->a.begin(), impl->a.end(), h_a.begin());
  thrust::copy(impl->b.begin(), impl->b.end(), h_b.begin());
  thrust::copy(impl->c.begin(), impl->c.end(), h_c.begin());
}

template <class T>
void ThrustStream<T>::copy()
{
  thrust::copy(impl->a.begin(), impl->a.end(),impl->c.begin());
  synchronise();
}

template <class T>
void ThrustStream<T>::mul()
{
  const T scalar = startScalar;
  thrust::transform(
      impl->c.begin(),
      impl->c.end(),
      impl->b.begin(),
      [=] __device__ __host__ (const T &ci){
        return ci * scalar;
      }
  );
  synchronise();
}

template <class T>
void ThrustStream<T>::add()
{
  thrust::transform(
      thrust::make_zip_iterator(impl->a.begin(), impl->b.begin()),
      thrust::make_zip_iterator(impl->a.end(), impl->b.end()),
      impl->c.begin(),
      thrust::make_zip_function(
          [] __device__ __host__ (const T& ai, const T& bi){
            return ai + bi;
          })
  );
  synchronise();
}

template <class T>
void ThrustStream<T>::triad()
{
  const T scalar = startScalar;
  thrust::transform(
      thrust::make_zip_iterator(impl->b.begin(), impl->c.begin()),
      thrust::make_zip_iterator(impl->b.end(), impl->c.end()),
      impl->a.begin(),
      thrust::make_zip_function(
          [=] __device__ __host__ (const T& bi, const T& ci){
            return bi + scalar * ci;
          })
  );
  synchronise();
}

template <class T>
void ThrustStream<T>::nstream()
{
  const T scalar = startScalar;
  thrust::transform(
      thrust::make_zip_iterator(impl->a.begin(), impl->b.begin(), impl->c.begin()),
      thrust::make_zip_iterator(impl->a.end(), impl->b.end(), impl->c.end()),
      impl->a.begin(),
      thrust::make_zip_function(
          [=] __device__ __host__ (const T& ai, const T& bi, const T& ci){
            return ai + bi + scalar * ci;
          })
  );
  synchronise();
}

template <class T>
T ThrustStream<T>::dot()
{
  return thrust::inner_product(impl->a.begin(), impl->a.end(), impl->b.begin(), T{});
}

#if THRUST_DEVICE_SYSTEM == THRUST_DEVICE_SYSTEM_CUDA || \
    (defined(THRUST_DEVICE_SYSTEM_HIP) && THRUST_DEVICE_SYSTEM_HIP == THRUST_DEVICE_SYSTEM)

#if defined(__NVCC__) || defined(__NVCOMPILER_CUDA__)
#define IMPL_FN__(fn) cuda ## fn
#define IMPL_TYPE__(tpe) cuda ## tpe
#elif defined(__HIP_PLATFORM_HCC__)
#define IMPL_FN__(fn) hip ## fn
#define IMPL_TYPE__(tpe) hip ## tpe ## _t
#else
# error Unsupported compiler for Thrust
#endif

void check_error()
{
  IMPL_FN__(Error_t) err =  IMPL_FN__(GetLastError());
  if (err !=  IMPL_FN__(Success))
  {
    std::cerr << "Error: " <<  IMPL_FN__(GetErrorString(err)) << std::endl;
    exit(err);
  }
}

void listDevices()
{
  // Get number of devices
  int count;
  IMPL_FN__(GetDeviceCount(&count));
  check_error();

  // Print device names
  if (count == 0)
  {
    std::cerr << "No devices found." << std::endl;
  }
  else
  {
    std::cout << std::endl;
    std::cout << "Devices:" << std::endl;
    for (int i = 0; i < count; i++)
    {
      std::cout << i << ": " << getDeviceName(i) << std::endl;
    }
    std::cout << std::endl;
  }
}

std::string getDeviceName(const int device)
{
  IMPL_TYPE__(DeviceProp) props = {};
  IMPL_FN__(GetDeviceProperties(&props, device));
  check_error();
  return std::string(props.name);
}


std::string getDeviceDriver(const int device)
{
  IMPL_FN__(SetDevice(device));
  check_error();
  int driver;
  IMPL_FN__(DriverGetVersion(&driver));
  check_error();
  return std::to_string(driver);
}

#undef IMPL_FN__
#undef IMPL_TPE__

#else

void listDevices()
{
  std::cout << "0: CPU" << std::endl;
}

std::string getDeviceName(const int)
{
  return std::string("(device name unavailable)");
}

std::string getDeviceDriver(const int)
{
  return std::string("(device driver unavailable)");
}

#endif

template class ThrustStream<float>;
template class ThrustStream<double>;


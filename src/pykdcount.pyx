#cython: embedsignature=True
#cython: cdivision=True
cimport numpy
import numpy
from cpython.mem cimport PyMem_Malloc, PyMem_Free, PyMem_Realloc
from libc.stdint cimport intptr_t as npy_intp
from libc.stdint cimport uint64_t as npy_uint64
numpy.import_array()

cdef extern from "kdcount.h":
    struct KDEnumData:
        double r 
        npy_intp i
        npy_intp j

    ctypedef double (*kd_castfunc)(void * p)
    ctypedef int (*kd_enum_callback)(void * data, KDEnumData * endata)
    struct cKDArray "KDArray":
        char * buffer
        npy_intp dims[2]
        npy_intp strides[2]
        npy_intp elsize
        double (* cast)(void * p1)
    
    struct cKDStore "KDStore":
        cKDArray input
        int thresh
        npy_intp * ind
        double * boxsize
        double p
        void * (*malloc)(npy_intp size)
        void * (*free)(npy_intp size, void * ptr)
        void * userdata
        npy_intp total_nodes

    struct cKDNode "KDNode":
        cKDStore * store
        cKDNode * link[2]
        npy_intp start
        npy_intp size
        int dim
        double split

    cKDNode * kd_build(cKDStore * store)
    double * kd_node_max(cKDNode * node)
    double * kd_node_min(cKDNode * node)
    void kd_free(cKDNode * node)
    void kd_free0(cKDStore * store, npy_intp size, void * ptr)
    cKDNode ** kd_tearoff(cKDNode * node, npy_intp thresh, npy_intp * length)
    int kd_enum(cKDNode * node[2], double maxr,
            kd_enum_callback callback, void * data) except -1
    int kd_count(cKDNode * node[2], double * r2,
            npy_uint64 * count, npy_intp Nbins) except -1

cdef class KDNode:
    cdef cKDNode * ref
    cdef readonly KDStore store 
    def __init__(self, store):
        self.store = store

    cdef void bind(self, cKDNode * ref) nogil:
        self.ref = ref

    property less:
        def __get__(self):
            cdef KDNode rt = KDNode(self.store)
            if self.ref.link[0]:
                rt.bind(self.ref.link[0])
                return rt
            else:
                return None

    property greater:
        def __get__(self):
            cdef KDNode rt = KDNode(self.store)
            if self.ref.link[1]:
                rt.bind(self.ref.link[1])
                return rt
            else:
                return None

    property start:
        def __get__(self):
            return self.ref.start
    
    property size:
        def __get__(self):
            return self.ref.size

    property dim:
        def __get__(self):
            return self.ref.dim

    property split:
        def __get__(self):
            return self.ref.split

    property max:
        def __get__(self):
            cdef double * max = kd_node_max(self.ref)
            return [max[d] for d in range(self.ref.store.input.dims[1])]

    property min:
        def __get__(self):
            cdef double * min = kd_node_min(self.ref)
            return [min[d] for d in range(self.ref.store.input.dims[1])]

    def __repr__(self):
        return str((self.dim, self.split, self.size))

    def tearoff(self, thresh):
        """
            tearoff a tree so that each returned 
            subtree is no bigger than thresh.
        """
        cdef cKDNode ** list
        cdef npy_intp len
        list = kd_tearoff(self.ref, thresh, &len)
        cdef npy_intp i
        ret = [KDNode(self.store) for i in range(len)]
        for i in range(len):
            (<KDNode>(ret[i])).bind(list[i])
        kd_free0(self.store.ref, len * sizeof(cKDNode*), list)
        return ret

    def count(self, KDNode other, r):
        r = numpy.atleast_1d(r).ravel()
        cdef numpy.ndarray r2 = numpy.empty(r.shape, dtype='f8')
        cdef numpy.ndarray count = numpy.zeros(r.shape, dtype='u8')
        cdef cKDNode * node[2]
        node[0] = self.ref
        node[1] = other.ref
        r2[:] = r * r
        kd_count(node, <double*>r2.data, <npy_uint64*>count.data, len(r))
        return count

    def enumiter(self, KDNode other, rmax, bunch=100000):
        """ cross correlate with other, for all pairs
            closer than rmax, iterate.

            for r, i, j in A.enumiter(...):
                ...
            where r is the distance, i and j are the original
            input array index of the data.

            This uses a thread to convert from KDNode.enum.
        """

        def feeder(process):
            self.enum(other, rmax, process, bunch)
        for r, i, j in makeiter(feeder):
            yield r, i, j

    def enum(self, KDNode other, rmax, process=None, bunch=10000, **kwargs):
        """ cross correlate with other, for all pairs
            closer than rmax, iterate.

            def process(r, i, j, **kwargs):
                ...

            A.enum(... process, **kwargs):
                ...

            where r is the distance, i and j are the original
            input array index of the data. arbitrary args can be passed
            to process via kwargs.
        """
        cdef int Nd = self.ref.store.input.dims[1]
        cdef numpy.ndarray r = numpy.empty(bunch, 'f8')
        cdef numpy.ndarray i = numpy.empty(bunch, 'intp')
        cdef numpy.ndarray j = numpy.empty(bunch, 'intp')

        cdef cKDNode * node[2]
        cdef CBData cbdata
        rall = None
        if process is None:
            rall = [numpy.empty(0, 'f8')]
            iall = [numpy.empty(0, 'intp')]
            jall = [numpy.empty(0, 'intp')]
            def process(r1, i1, j1, **kwargs):
                rall[0] = numpy.append(rall[0], r1)
                iall[0] = numpy.append(iall[0], i1)
                jall[0] = numpy.append(jall[0], j1)

        def func():
            process(r[:cbdata.length].copy(), 
                    i[:cbdata.length].copy(), 
                    j[:cbdata.length].copy(),
                    **kwargs)
        node[0] = self.ref
        node[1] = other.ref
        cbdata.notify = <void*>func
        cbdata.Nd = Nd
        cbdata.r = <double*>r.data
        cbdata.i = <npy_intp*>i.data
        cbdata.j = <npy_intp*>j.data
        cbdata.size = bunch
        cbdata.length = 0
        kd_enum(node, rmax, <kd_enum_callback>callback, &cbdata)

        if cbdata.length > 0:
            func()

        if rall is not None:
            return rall[0], iall[0], jall[0]
        else:
            return None

cdef double dcast(double * p1) nogil:
    return p1[0]
cdef double fcast(float * p1) nogil:
    return p1[0]

cdef struct CBData:
    double * r
    npy_intp * i
    npy_intp * j
    double * x
    double * y
    npy_intp size
    npy_intp length
    void * notify
    int Nd

cdef int callback(CBData * data, KDEnumData * endata) except -1:
    if data.length == data.size:
        (<object>(data.notify)).__call__()
        data.length = 0
    cdef int d
    data.r[data.length] = endata.r
    data.i[data.length] = endata.i
    data.j[data.length] = endata.j

    data.length = data.length + 1
    return 0

cdef class KDStore:
    cdef cKDStore * ref
    cdef cKDNode * tree
    cdef readonly numpy.ndarray input
    cdef readonly numpy.ndarray ind
    cdef readonly numpy.ndarray boxsize
    property strides:
        def __get__(self):
            return [self.ref.input.strides[i] for i in range(2)]
    property root:
        def __get__(self):
            cdef KDNode rt = KDNode(self)
            rt.bind(self.tree)
            return rt
    property size:
        def __get__(self):
            return self.ref.total_nodes

    def __init__(self, numpy.ndarray input, boxsize=None):
        if input.ndim != 2:
            raise ValueError("input needs to be a 2 D array of (N, Nd)")
        self.input = input
        self.ref = <cKDStore*>PyMem_Malloc(sizeof(cKDStore))
        self.ref.input.buffer = input.data
        self.ref.input.dims[0] = input.shape[0]
        self.ref.input.dims[1] = input.shape[1]
        self.ref.input.strides[0] = input.strides[0]
        self.ref.input.strides[1] = input.strides[1]
        self.ref.thresh = 10
        self.ind = numpy.empty(self.ref.input.dims[0], dtype='intp')
        self.ref.ind = <npy_intp*> self.ind.data
        if boxsize != None:
            self.boxsize = numpy.empty(self.ref.input.dims[1], dtype='f8')
            self.boxsize[:] = boxsize
            self.ref.boxsize = <double*>self.boxsize.data
        else:
            self.boxsize = None
            self.ref.boxsize = NULL
        self.ref.input.elsize = input.dtype.itemsize
        if input.dtype.char == 'f':
            self.ref.input.cast = <kd_castfunc>fcast
        if input.dtype.char == 'd':
            self.ref.input.cast = <kd_castfunc>dcast
        self.ref.malloc = NULL
        self.ref.free = NULL
        self.tree = kd_build(self.ref)

    def __dealloc__(self):
        if self.tree:
            kd_free(self.tree)
        PyMem_Free(self.ref)

def build(numpy.ndarray data, boxsize=None):
    store = KDStore(data, boxsize)
    return store.root

import threading
import Queue
import signal
def makeiter(feeder):
    q = Queue.Queue(2)
    def process(*args):
        q.put(args)
    def wrap(process):
        try:
            feeder(process)
        except Exception as e:
            q.put(e)
        finally:
            q.put(StopIteration)
    old = signal.signal(signal.SIGINT, signal.SIG_IGN)
    t = threading.Thread(target=wrap, args=(process,))
    t.start()
    signal.signal(signal.SIGINT, old)
    while True:
        item = q.get()
        if item is StopIteration:
            q.task_done()
            break
        elif isinstance(item, Exception):
            q.task_done()
            raise item
        else:
            if len(item) == 1: item = item[0]
            yield item
            q.task_done()
    q.join()


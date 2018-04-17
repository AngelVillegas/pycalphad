cimport cython
from cpython.mem cimport PyMem_Malloc, PyMem_Free
import numpy as np
cimport numpy as np
from cpython cimport PyCapsule_CheckExact, PyCapsule_GetPointer
import pycalphad.variables as v

# From https://gist.github.com/pv/5437087
cdef void* cython_pointer(obj):
    if PyCapsule_CheckExact(obj):
        return PyCapsule_GetPointer(obj, NULL);
    raise ValueError("Not an object containing a void ptr")


cdef public class PhaseRecord(object)[type PhaseRecordType, object PhaseRecordObject]:
    """
    This object exposes a common API to the solver so it doesn't need to know about the differences
    between Model and CompiledModel. Each PhaseRecord holds a reference to its own Model or CompiledModel;
    these objects are pickleable. PhaseRecords are immutable after initialization.
    """

    def __dealloc__(self):
        PyMem_Free(self._masses)
        PyMem_Free(self._massgrads)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cpdef void obj(self, double[::1] out, double[:,::1] dof) nogil:
        if self._obj != NULL:
            self._obj(&out[0], &dof[0,0], &self.parameters[0], <int>out.shape[0])

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cpdef void grad(self, double[::1] out, double[::1] dof) nogil:
        if self._grad == NULL:
            with gil:
                self._gfunc.kernel
                self._grad = <func_novec_t*> cython_pointer(self._gfunc._cpointer)
        self._grad(&dof[0], &self.parameters[0], &out[0])

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cpdef void hess(self, double[:,::1] out, double[::1] dof) nogil:
        if self._hess != NULL:
            self._hess(&dof[0], &self.parameters[0], &out[0,0])

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cpdef void internal_constraints(self, double[::1] out, double[::1] dof) nogil:
        if self._internal_cons == NULL:
            with gil:
                self._intconsfunc.kernel
                self._internal_cons = <func_novec_t*> cython_pointer(self._intconsfunc._cpointer)
        self._internal_cons(&dof[0], &self.parameters[0], &out[0])

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cpdef void internal_jacobian(self, double[:, ::1] out, double[::1] dof) nogil:
        if self._internal_jac == NULL:
            with gil:
                self._intjacfunc.kernel
                self._internal_jac = <func_novec_t*> cython_pointer(self._intjacfunc._cpointer)
        self._internal_jac(&dof[0], &self.parameters[0], &out[0,0])

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cpdef void multiphase_constraints(self, double[::1] out, double[::1] dof) nogil:
        if self._multiphase_cons == NULL:
            with gil:
                self._mpconsfunc.kernel
                self._multiphase_cons = <func_novec_t*> cython_pointer(self._mpconsfunc._cpointer)
        self._multiphase_cons(&dof[0], &self.parameters[0], &out[0])

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cpdef void multiphase_jacobian(self, double[:, ::1] out, double[::1] dof) nogil:
        if self._multiphase_jac == NULL:
            with gil:
                self._mpjacfunc.kernel
                self._multiphase_jac = <func_novec_t*> cython_pointer(self._mpjacfunc._cpointer)
        self._multiphase_jac(&dof[0], &self.parameters[0], &out[0,0])

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cpdef void mass_obj(self, double[::1] out, double[:, ::1] dof, int comp_idx) nogil:
        if self._masses != NULL:
            self._masses[comp_idx](&out[0], &dof[0,0], &self.parameters[0], <int>out.shape[0])

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cpdef void mass_grad(self, double[::1] out, double[::1] dof, int comp_idx) nogil:
        if self._massgrads != NULL:
            self._massgrads[comp_idx](&dof[0], &self.parameters[0], &out[0])


cpdef PhaseRecord PhaseRecord_from_cython(object comps, object variables, double[::1] num_sites, double[::1] parameters,
                                          object ofunc, object gfunc, object hfunc, object massfuncs,
                                          object massgradfuncs, object internal_cons_func, object internal_jac_func,
                                          object multiphase_cons_func, object multiphase_jac_func,
                                          size_t num_internal_cons, size_t num_multiphase_cons):
    cdef:
        int var_idx, subl_index, el_idx
        PhaseRecord inst
    desired_active_pure_elements = [list(x.constituents.keys()) for x in comps]
    desired_active_pure_elements = [el.upper() for constituents in desired_active_pure_elements for el in constituents]
    pure_elements = sorted(set(desired_active_pure_elements))
    nonvacant_elements = sorted([x for x in set(desired_active_pure_elements) if x != 'VA'])
    inst = PhaseRecord()
    # XXX: Missing inst.phase_name
    # XXX: Doesn't refcounting need to happen here to keep the codegen objects from disappearing?
    inst.variables = variables
    inst.phase_dof = 0
    inst.sublattice_dof = np.zeros(num_sites.shape[0], dtype=np.int32)
    inst.parameters = parameters
    inst.num_sites = num_sites
    inst.num_internal_cons = num_internal_cons
    inst.num_multiphase_cons = num_multiphase_cons
    inst.composition_matrices = np.full((len(pure_elements), num_sites.shape[0], 2), -1.)
    if 'VA' in pure_elements:
        inst.vacancy_index = pure_elements.index('VA')
    else:
        inst.vacancy_index = -1
    var_idx = 0
    for variable in variables:
        if not isinstance(variable, v.SiteFraction):
            continue
        inst.phase_name = <unicode>variable.phase_name
        subl_index = variable.sublattice_index
        inst.sublattice_dof[subl_index] += 1
        var_idx += 1
        inst.phase_dof += 1
    # Trigger lazy computation
    if ofunc is not None:
        inst._ofunc = ofunc
        ofunc.kernel
        inst._obj = <func_t*> cython_pointer(ofunc._cpointer)
    if gfunc is not None:
        inst._gfunc = gfunc
    inst._grad = NULL
    if hfunc is not None:
        inst._hfunc = hfunc
        hfunc.kernel
        inst._hess = <func_novec_t*> cython_pointer(hfunc._cpointer)
    if internal_cons_func is not None:
        inst._intconsfunc = internal_cons_func
    inst._internal_cons = NULL
    if internal_jac_func is not None:
        inst._intjacfunc = internal_jac_func
    inst._internal_jac = NULL
    if multiphase_cons_func is not None:
        inst._mpconsfunc = multiphase_cons_func
    inst._multiphase_cons = NULL
    if multiphase_jac_func is not None:
        inst._mpjacfunc = multiphase_jac_func
    inst._multiphase_jac = NULL
    if massfuncs is not None:
        inst._massfuncs = massfuncs
        inst._masses = <func_t**>PyMem_Malloc(len(pure_elements) * sizeof(func_t*))
        for el_idx in range(len(nonvacant_elements)):
            massfuncs[el_idx].kernel
            inst._masses[el_idx] = <func_t*> cython_pointer(massfuncs[el_idx]._cpointer)
    if massgradfuncs is not None:
        inst._massgradfuncs = massgradfuncs
        inst._massgrads = <func_novec_t**>PyMem_Malloc(len(nonvacant_elements) * sizeof(func_novec_t*))
        for el_idx in range(len(nonvacant_elements)):
            massgradfuncs[el_idx].kernel
            inst._massgrads[el_idx] = <func_novec_t*> cython_pointer(massgradfuncs[el_idx]._cpointer)
    return inst


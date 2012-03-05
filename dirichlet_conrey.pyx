#
# A new implementation of Dirichlet characters based on the numbering scheme
# devised by Brian Conrey.
#

from sage.all import factor, primitive_root, euler_phi, gcd, exp, is_prime, DirichletGroup, vector, Integer
from sage.modular.dirichlet import DirichletCharacter

cdef complex twopii = 3.1415926535897932384626433833 * 2.0 * 1.0j

cdef class DirichletGroup_conrey:

    #
    # Note: perhaps the discrete log tables should be stored
    # separately for each prime. This will make computation a
    # little slower, but it would be possible to work efficiently
    # when the modulus is huge but divisible only by small primes
    # to small powers.
    #
    # Random question for self: Given a discrete log table mod p,
    # is it easy to solve the discrete log problem mod p^a? If so,
    # it would be possible to remove the last three words from the
    # above paragraph.
    #


    cdef long q             # the modulus
                            
    cdef long q_even        # for computation we will strip out the even
    cdef long q_odd         # factors from the modulus. q == q_even * q_odd
                            
    cdef long k             # the number of factors of q_odd
                            
    cdef long * primes      # a list of prime factors of the modulus
    cdef long * exponents   # a list of the exponents of those prime factors in the factorization
    cdef long * generators  # a primitive root for each prime factor

    cdef long * A           # exponent vectors:
                            # for each m coprime to q_odd we store an array
                            # with the property that
                            #
                            #   m == g[j]**A[m][j] mod p[j]**e[j]
                            #
                            # (where "A[m][k] == A[m * self.k + j]")
                            #
                            # where g[j] is a primitive root mod p[j]**e[j],
                            # and p[j] is the j-th prime factor of q_odd.
                            #
                            # This array is the obstacle that will prevent this
                            # implementation from working reasonably for very
                            # large modulus. We will need something else which
                            # does not use any precomputation for that case.
 
    cdef long * B           # exponents for q_even:
                            # for each odd m, 0 <= m < q_even, we will compute B
                            # so that
                            # 
                            #   m == B[m-1] * 3**B[m] mod q_even,
                            # 
                            # where B[m-1] = +- 1 and 0 <= B[m] < q_even/4

    cdef long * PHI         # PHI[j] = phi(q_odd)/phi(p[j]**e[j]). This will make it easier
                            # to compute the characters.

    cdef long phi_q_odd     # phi(q_odd)
    cdef long phi_q         # phi(q)
    
    cdef complex * zeta_powers_odd  # an array holding powers of a root of unity.
                                    # this should be the only part of the code that
                                    # needs to change in order to work over a cyclotomic field

    cdef complex * zeta_powers_even # for the even part of the character
    
    cdef _standard_dirichlet_group

    def __cinit__(self, modulus, basering = None):
        try:
            self.q = modulus
        except OverflowError:
            raise NotImplementedError("Currently this implementation does not allow a modulus that large.")
            
        self.q_even = 1
        self.q_odd = self.q
        while self.q_odd % 2 == 0:
            self.q_odd = self.q_odd/2
            self.q_even = self.q_even * 2

        if self.q_odd > 1:
            X = factor(self.q_odd)
            self.k = len(X)
            self.primes = <long *>malloc(self.k * sizeof(long))
            self.exponents = <long *>malloc(self.k * sizeof(long))
            for n in range(self.k):
                self.primes[n] = X[n][0]
                self.exponents[n] = X[n][1]
            self.generators = <long *>malloc(self.k * sizeof(long))
            self.PHI = <long *>malloc(self.k * sizeof(long))
            self.A = <long*>malloc(self.q_odd * self.k * sizeof(long))
            self.zeta_powers_odd = <complex*>malloc(self.q * sizeof(complex))

        if self.q_even > 4:
            # We are only going to use zeta_powers_even if q_even is large enough.
            # When q_even == 2, it would just be {1}, and when q_even == 4, it
            # would just be {1,-1}.
            #
            # This way, it is always the case that, if zeta_powers_even has been
            # initialized, it will be of size q_even/4

            self.B = <long*>malloc(self.q_even * sizeof(long))
            self.zeta_powers_even = <complex*>malloc(self.q_even/4 * sizeof(complex))

    def __init__(self, modulus, basering = None):
        # Once we've hit this stage, all of our arrays are allocated,
        # and both self.prime and self.exponents contain the right things.
        #
        # We now set up the rest of the precomputed arrays.

        self.phi_q_odd = euler_phi(self.q_odd)
     
        if self.q_even > 1:
            self.phi_q = self.phi_q_odd * self.q_even/2
        else:
            self.phi_q = self.phi_q_odd

        cdef long g
        cdef long a
        for j in range(self.k):
            x = self.primes[j]**self.exponents[j]
            g = primitive_root(x)
            self.generators[j] = g
            phi = self.primes[j]**(self.exponents[j] - 1) * (self.primes[j] - 1)
            self.PHI[j] = self.phi_q_odd/phi
            a = 1
            for l in range(phi):
                for m in range(a, self.q_odd, x):
                    self.A[m * self.k + j] = l
                a = (a * g) % x
        #
        # Store a flag in A for each m that is not coprime to q_odd.
        # (This will save on expensive gcd computations later.)
        #
        if self.q_odd > 1:
            for m in range(self.q_odd):
                if gcd(m,self.q_odd) > 1:
                    self.A[m * self.k] = -1

        #
        # Compute a table of powers of the root of unity. This will
        # save on expensive calls to exp() later. It does increase
        # memory usage by an appreciable amount, though, so we might
        # want to add an option to not do this.
        #
        # We will _need_ to not do this later when allowing very
        # large moduli.
        #
        if self.q_odd > 1:
            for n in range(self.phi_q_odd):
                self.zeta_powers_odd[n] = exp(twopii * n/<double>self.phi_q_odd)

        cdef long pow_three = 1
        if self.q_even > 4:
            for n in range(self.q_even/4):
                self.zeta_powers_even[n] = exp(twopii * n * 4/<double>self.q_even)

            for e in range(self.q_even/4):
                self.B[pow_three] = e
                self.B[pow_three - 1] = 1
                self.B[self.q_even - pow_three] = e
                self.B[self.q_even - pow_three - 1] = -1
                pow_three = pow_three * 3
                pow_three = pow_three % self.q_even

    cpdef long _chi_odd_exponent(self, long m, long n):
        r"""
        BE CAREFUL CALLING THIS. It implicitly assumes:
            - 1 <= m < self.q_odd
            - 1 <= n < self.q_odd
            - gcd(m, self.q_odd) == 1
            - gcd(n, self.q_odd) == 1
            - (anything else?)
        """
        cdef long x = 0
        for j in range(self.k):
            x += self.A[m * self.k + j]*self.A[n * self.k + j]*self.PHI[j]
            x = x % self.phi_q_odd
        return x;

    cpdef long _chi_even_exponent(self, long m, long n):
        r"""
        BE CAREFUL CALLING THIS. It implicitly assumes that:
            - 0 < m < self.q_even
            - 0 < n < self.q_even
            - self.q_even > 4
            - m and n are odd
        """
        cdef long exponent = self.B[m]*self.B[n]
        if self.B[m-1] == -1 and self.B[n-1] == -1:
            exponent += self.q_even/8
        return exponent % (self.q_even/4)

    cpdef complex chi(self, long m, long n):
        cdef complex odd_part = 1
        cdef complex even_part = 1
        if self.q_even > 1:
            if m % 2 == 0 or n % 2 == 0:
                return 0
            elif self.q_even == 2:
                even_part = 1
            elif self.q_even == 4:
                if m % 4 == 3 and n % 4 == 3:
                    even_part = -1
                else:
                    even_part = 1
            else:
                even_part = self.zeta_powers_even[self._chi_even_exponent(m % self.q_even, n % self.q_even)]
        if self.q_odd > 1:
            m = m % self.q_odd
            n = n % self.q_odd
            if self.A[m * self.k] == -1 or self.A[n * self.k] == -1:
                odd_part = 0;
            else:
                odd_part = self.zeta_powers_odd[self._chi_odd_exponent(m,n)]

        return even_part * odd_part

    def __iter__(self):
        cdef long n = 1
        while n < self.q:
            if self.q_odd == 1 or self.A[(n % self.q_odd) * self.k] != -1:
                if self.q_even == 1 or n % 2 == 1:
                    yield self._getitem_(n)
            n = n + 1

    def primitive_characters(self):
        for chi in self:
            if chi.is_primitive():
                yield chi

    def __dealloc__(self):
        if self.primes != NULL:
            free(self.primes)
        if self.exponents != NULL:
            free(self.exponents)
        if self.generators != NULL:
            free(self.generators)
        if self.PHI != NULL:
            free(self.PHI)
        if self.A != NULL:
            free(self.A)
        if self.zeta_powers_odd != NULL:
            free(self.zeta_powers_odd)
        if self.zeta_powers_even != NULL:
            free(self.zeta_powers_even)
        if self.B != NULL:
            free(self.B)

    def __getitem__(self, n):
        return self._getitem_(n)

    cdef DirichletCharacter_conrey _getitem_(self, long n):
        return DirichletCharacter_conrey(self, n)

    def __repr__(self):
        return "Group of dirichlet characters with modulus %d" % self.q

    def standard_dirichlet_group(self):
        """
        Return the "standard" Sage Dirichlet group with the same modulus,
        when characters taking values in a cyclotomic field. This is only
        computed when it is asked for, but it is cached after being
        computed.

        Maybe this function needs a better name.
        """

        if self._standard_dirichlet_group is None:
            self._standard_dirichlet_group = DirichletGroup(self.q)

        return self._standard_dirichlet_group


cdef class DirichletCharacter_conrey:
    cdef long _n        # we will store the number used to create this character,
    cdef number         # e.g., -1, but for all computations we use _n, which is number % q.

    cdef DirichletGroup_conrey _parent

    def __init__(self, DirichletGroup_conrey parent, long n):
        """
            The nth character for the Dirichlet Group parent.
        """
        self._parent = parent
        self.number = n
        self._n = n % parent.q

    def __call__(self, long m):
        return self.value(m)

    cpdef value(self, long m):
        return self._parent.chi(self._n, m)

    def values(self):
        return [self(m) for m in xrange(self._parent.q)]

    cpdef long exponent(self, long m):
        r"""
        Return the number a such that chi(m) = e(a/phi(q)).
        """
        cdef long exponent
        cdef long q_even = self._parent.q_even
        cdef long q_odd = self._parent.q_odd

        if q_odd > 1:
            odd_exponent = self._parent._chi_odd_exponent(self._n % q_odd, m % q_odd)
        else:
            odd_exponent = 0

        if q_even > 4:
            even_exponent = self._parent._chi_even_exponent(self._n % q_even, m % q_even)
            even_exponent *= 2  # the function just above computes the exponent of
                                # e(1/ (q_even/4) ), but we want the exponent of
                                # e(1/phi(q_even)) = e(1/(q_even/2))
        elif q_even == 4:
            if (self._n % q_even) == 3 and (m % q_even) == 3:
                even_exponent = 1
            else:
                even_exponent = 0
        else:
            even_exponent = 0

        if q_even == 1: # special case because phi(1) != 1/2.
            exponent = odd_exponent
        else:
            exponent = odd_exponent * q_even/2 + even_exponent * self._parent.phi_q_odd
    
        # we now have the value of chi(m) as e(exponent/phi(q))

        # it could be equal to phi(q), though, and in that case we
        # want it to be zero...
        if exponent == self._parent.phi_q:
            exponent -= self._parent.phi_q

        return exponent

    def logvalue(self, long m):
        r"""
        Return log(chi(m))/(2 pi i) as a rational number; i.e., return a/b
        so that chi(m) = e(a/b). 
        """
        cdef long exponent = self.exponent(m)
        return Integer(exponent)/Integer(self._parent.phi_q) # TODO: there is probably
                                                             # a better way to construct
                                                             # a rational number.

    cpdef is_even(self):
        return self.exponent(-1) == 0

    cpdef is_odd(self):
        return self.exponent(-1) != 0

    def is_trivial(self):
        return self._n == 1

    def kernel(self):
        return [n for n in range(self._parent.q) if self.exponent(n) == 0]

    def modulus(self):
        return self._parent.q

    def __repr__(self):
        return "Dirichlet character with index %d modulo %d" % (self._n, self._parent.q)

    def primitive_at_p(self, p):
        r"""
        Return whether or not the character is primitive at the prime p. We
        call a character `\chi_q(n, -)` primitive at p if the character
        `\chi_{p^a}(n, -)` is primitive, where `p^a` is the largest power
        of `p` dividing `q`.
        """

        if not is_prime(p):
            raise TypeError("p must be prime.")

        cdef long _p = p
        cdef long g

        raise NotImplementedError("Maybe I'll do this later. Or maybe I'll delete this function.")

    cdef int _primitive_at_known_p(self, long j):
        r"""
        Return whether or not this character is primitive at the jth prime
        factor of the odd part of the modulus.
        """

        cdef long p = self._parent.primes[j]
        n = self._n % self._parent.q_odd
        cdef long dlog = self._parent.A[n * self._parent.k + j]
        return dlog % p != 0

    cdef is_primitive_at_two(self):
        cdef long q_even = self._parent.q_even
        cdef long * B = self._parent.B
        cdef long n = self._n % q_even
        if q_even == 1:
            return True
        elif q_even == 2:
            return False
        elif q_even == 4:
            return n == 3
        elif q_even == 8:
            if B[n] % 2 == 1 and B[n-1] == 1:
                return True
            elif B[n] % 2 == 0 and B[n-1] == -1:
                return True
            else:
                return False
        else:
            return B[n] % 2 == 1

    def is_primitive(self):
        """
        Return whether or not this character is primitive.
        """

        for j in range(self._parent.k):
            if not self._primitive_at_known_p(j):
                return False

        return self.is_primitive_at_two()

    def sage_character(self):
        """
        return the sage.modular.dirichlet.DirichletCharacter that corresponds
        to this character.

        This function has a stupid name, because eventually this code should
        be part of Sage, so there will be two available implementations. I
        don't know what to call it right now.
        """

        G = self._parent.standard_dirichlet_group()

        gens = G.unit_gens()  # grabbing the generators this way
                              # ensures that they will be the same
                              # generators used by the
                              # DirichletGroup_class

        # We can construct a DirichletCharacter by giving it
        # a list of the exponents on the generators, so we
        # compute these.
        
        # Because we are computing the odd and even parts of
        # the character separately, we have to properly combine
        # the exponents.

        cdef long zeta_order = G.zeta_order()
        exponents = []
        for a in gens:
            exponent = (self.exponent(a) * zeta_order)/self._parent.phi_q

            exponents.append(exponent)

        # To make sure that the exponent vector has the right type, I'm
        # mimicking a bit what is done in modular/dirichlet.pyx, without
        # necessarily understanding if what I'm doing it right.
        # 
        # Thus I put the XXX here to mark this as a possible trouble
        # spot if there are problems in the future...

        M = self._parent.standard_dirichlet_group()._module

        exponents = M(exponents)
        return DirichletCharacter(self._parent.standard_dirichlet_group(), exponents)


    #cdef complex __call__unsafe(self, long m):
    #    return self.parent._chi_unsafe(self._n, m)
